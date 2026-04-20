// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import LiveKit
import RelayInterface
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "RelayKit", category: "Call")

/// A concrete ``CallViewModelProtocol`` implementation backed by the LiveKit Swift SDK.
///
/// ``CallViewModel`` owns a `LiveKit.Room` instance and bridges its delegate callbacks
/// into ``@Observable`` state for SwiftUI consumption.
///
/// The inner ``Delegate`` class implements `RoomDelegate` and dispatches all callbacks
/// onto the main actor via `Task { @MainActor in … }` so that UI state mutations are
/// always performed on the correct actor without requiring LiveKit itself to be
/// `@MainActor`-aware.
@Observable
@MainActor
public final class CallViewModel: CallViewModelProtocol {
    public private(set) var state: CallState = .idle
    public private(set) var participants: [CallParticipant] = []
    public private(set) var isLocalCameraEnabled: Bool = false
    public private(set) var isLocalMicrophoneEnabled: Bool = false
    public private(set) var localParticipantID: String?
    /// Incremented whenever video tracks change, triggering SwiftUI to
    /// re-evaluate `videoContent(for:)` and pick up new or removed tracks.
    public private(set) var videoTrackRevision: UInt = 0

    @ObservationIgnored
    private let room = LiveKit.Room()
    @ObservationIgnored
    private var delegate: Delegate?

    /// Cached video views keyed by participant ID, to avoid recreating
    /// `SwiftUIVideoView` on every SwiftUI re-render.  Each entry stores
    /// the `ObjectIdentifier` of the `VideoTrack` so the cache is
    /// invalidated when the underlying track actually changes.
    ///
    /// `@ObservationIgnored` is critical: without it, the `@Observable`
    /// macro tracks writes to this cache, and because `makeVideoView` is
    /// called directly from SwiftUI view bodies, any cache mutation during
    /// body evaluation triggers an invalidation which re-runs the body
    /// which re-mutates the cache — leading to a constraint-pass crash:
    /// "more Update Constraints in Window passes than there are views".
    @ObservationIgnored
    private var videoViewCache: [String: (trackObjectID: ObjectIdentifier, view: AnyView)] = [:]

    // MARK: - E2EE State
    //
    // All of these are implementation details — no SwiftUI view reads
    // them. Marking them `@ObservationIgnored` keeps their writes out of
    // the observation registrar, which eliminates a class of stray
    // invalidations that otherwise pile up during call startup when
    // `connect()` writes the key, members, and bridge in rapid succession
    // on the main actor.

    /// The LiveKit key provider used for per-participant AES-GCM frame encryption.
    @ObservationIgnored
    private var keyProvider: BaseKeyProvider?
    /// The local participant's current encryption key (raw 16 bytes).
    @ObservationIgnored
    private var localEncryptionKey: Data?
    /// The current key index (0-255, wraps around on ratchet).
    @ObservationIgnored
    private var localKeyIndex: Int = 0
    /// Service for MatrixRTC call-member signaling and LiveKit key plumbing.
    @ObservationIgnored
    private var encryptionService: CallEncryptionService?
    /// The Matrix SDK room, used for the widget bridge.
    @ObservationIgnored
    private var matrixRoom: MatrixRustSDK.Room?
    /// Headless widget-driver bridge that handles Olm-encrypted key exchange
    /// via the Matrix Widget API. Nil until `connect(...)` completes setup.
    @ObservationIgnored
    private var widgetBridge: CallWidgetBridge?
    /// Cached user/device map of known call members, rebuilt from
    /// MatrixRTC member state events.
    @ObservationIgnored
    private var callMembers: [String: [String]] = [:]

    /// Creates a call view model without E2EE. Use ``init(encryptionContext:)``
    /// for encrypted calls that interoperate with Element Call.
    public init() {
        self.isE2eeEnabled = false
        let delegate = Delegate(viewModel: self)
        self.delegate = delegate
        room.add(delegate: delegate)
    }

    /// Encryption context passed from ``MatrixService`` to enable E2EE key exchange.
    public struct EncryptionContext: @unchecked Sendable {
        public let homeserver: String
        public let accessToken: String
        public let userID: String
        public let deviceID: String
        public let roomID: String
        /// Whether the Matrix room has encryption enabled (`m.room.encryption` state event).
        /// When `true`, LiveKit-level GCM frame encryption + key exchange is enabled.
        public let isRoomEncrypted: Bool
        /// The Matrix SDK room, used to obtain the timeline for listening to
        /// inbound encryption key state events. `nil` if unavailable.
        public let matrixRoom: MatrixRustSDK.Room?

        public init(homeserver: String, accessToken: String, userID: String, deviceID: String, roomID: String, isRoomEncrypted: Bool = false, matrixRoom: MatrixRustSDK.Room? = nil) {
            self.homeserver = homeserver
            self.accessToken = accessToken
            self.userID = userID
            self.deviceID = deviceID
            self.roomID = roomID
            self.isRoomEncrypted = isRoomEncrypted
            self.matrixRoom = matrixRoom
        }
    }

    /// Whether this call uses LiveKit-level E2EE (GCM frame encryption).
    /// Mirrors the Matrix room's encryption state.
    private let isE2eeEnabled: Bool

    /// Creates a call view model with optional E2EE, determined by the Matrix
    /// room's encryption state. Encrypted rooms use AES-128-GCM frame encryption
    /// with MatrixRTC key exchange; unencrypted rooms use no LiveKit-level E2EE.
    public init(encryptionContext: EncryptionContext) {
        self.isE2eeEnabled = encryptionContext.isRoomEncrypted

        let delegate = Delegate(viewModel: self)
        self.delegate = delegate
        room.add(delegate: delegate)

        self.encryptionService = CallEncryptionService(
            homeserver: encryptionContext.homeserver,
            accessToken: encryptionContext.accessToken,
            userID: encryptionContext.userID,
            deviceID: encryptionContext.deviceID,
            roomID: encryptionContext.roomID,
            sdkRoom: encryptionContext.matrixRoom
        )

        if encryptionContext.isRoomEncrypted {
            // Per-participant key provider: each participant has their own key.
            // Match Element Call's MatrixKeyProvider configuration so the JS
            // LiveKit E2EE worker doesn't exhaust its ratchet window trying to
            // decrypt our frames. Swift BaseKeyProvider defaults are
            // ratchetWindowSize: 0, keyRingSize: 16; Element Call uses 10/256.
            //
            // Additionally: swap in an HKDF-SHA256-backed
            // LKRTCFrameCryptorKeyProvider. The LiveKit Swift SDK's default
            // initializer path constructs the ObjC provider with PBKDF2
            // (libwebrtc's default), but Element Call / livekit-client JS
            // derives the AES-GCM key with HKDF from the same raw IKM —
            // so the two sides produce different AES keys from matching
            // fingerprints, and every frame's auth tag fails on the peer.
            // See CallEncryptionService.makeHKDFKeyProvider for details.
            self.keyProvider = CallEncryptionService.makeHKDFKeyProvider(
                ratchetWindowSize: 10,
                keyRingSize: 256
            )
        }
        self.matrixRoom = encryptionContext.matrixRoom
    }

    // MARK: - CallViewModelProtocol

    public func connect(url: String, token: String, sfuServiceURL: String = "") async throws {
        state = .connecting
        do {
            // Microphone publish is deferred until AFTER the local E2EE key
            // has been installed and distributed to peers. If we let
            // LiveKit auto-publish the mic at connect time, the first
            // audio frames hit the SFU before peers receive our key —
            // their frame cryptor then ratchets past its window and
            // poisons the key slot.
            let connectOpts = ConnectOptions(
                autoSubscribe: true,
                enableMicrophone: false
            )

            // Enable LiveKit-level GCM frame encryption only for encrypted Matrix
            // rooms. Element Call also uses LiveKit E2EE (SFrame) for encrypted
            // rooms and no encryption for unencrypted rooms.
            let encryptionOpts: EncryptionOptions? = keyProvider.map {
                EncryptionOptions(keyProvider: $0, encryptionType: .gcm)
            }
            if isE2eeEnabled {
                logger.info("E2EE enabled (encrypted Matrix room)")
            } else {
                logger.info("E2EE disabled (unencrypted Matrix room)")
            }
            let roomOpts = RoomOptions(
                defaultVideoPublishOptions: VideoPublishOptions(
                    preferredCodec: .vp8
                ),
                defaultAudioPublishOptions: AudioPublishOptions(
                    dtx: true,
                    red: false
                ),
                adaptiveStream: true,
                dynacast: true,
                encryptionOptions: encryptionOpts
            )
            try await room.connect(
                url: url,
                token: token,
                connectOptions: connectOpts,
                roomOptions: roomOpts
            )
            localParticipantID = room.localParticipant.identity?.stringValue
            logger.info("Connected with LiveKit identity: \(self.localParticipantID ?? "unknown", privacy: .public)")

            // Spin up the headless widget bridge *only* for encrypted rooms.
            // For unencrypted rooms the bridge adds no value (no keys to
            // exchange) and materialising a virtual Element-Call widget on
            // a room Element-X is already observing causes Element-X to
            // stall before joining the LiveKit SFU.
            if self.isE2eeEnabled, let matrixRoom, let encryptionService {
                do {
                    let bridge = try CallWidgetBridge(
                        room: matrixRoom,
                        ownUserId: encryptionService.userID,
                        ownDeviceId: encryptionService.deviceID,
                        isRoomEncrypted: true,
                        keyProvider: self.keyProvider
                    )
                    bridge.start()
                    self.widgetBridge = bridge
                } catch {
                    logger.error("Failed to create CallWidgetBridge: \(error.localizedDescription)")
                }
            }

            // CRITICAL: Register the local E2EE key in the keyProvider
            // BEFORE publishing any media tracks. LiveKit begins encrypting
            // frames the instant `setCamera(enabled: true)` attaches the
            // track, so if the key isn't installed yet the first batch of
            // frames is encrypted with nothing the remote peer can decrypt —
            // and Element-X's video decoder stalls on that first undecodable
            // frame, resulting in perpetual black video.
            if self.isE2eeEnabled, let keyProvider = self.keyProvider, let encryptionService {
                let key = CallEncryptionService.generateKey()
                self.localEncryptionKey = key
                // Legacy `m.call.member` rtcBackendIdentity is always
                // `${sender}:${device_id}` (matrix-js-sdk CallMembership.ts
                // line 101). This is what remote peers route our frames under,
                // so our local sender cryptor MUST be keyed under the same
                // byte sequence — do not trust `localParticipantID` (the
                // identity LiveKit assigns from the SFU JWT), since a
                // mismatched JWT identity would silently break decrypt.
                let localIdentity = "\(encryptionService.userID):\(encryptionService.deviceID)"
                if let livekitIdentity = self.localParticipantID, livekitIdentity != localIdentity {
                    logger.warning("LiveKit identity \(livekitIdentity, privacy: .public) != matrix identity \(localIdentity, privacy: .public) — frame encryption may misroute")
                }
                let keyIndex = self.localKeyIndex
                CallEncryptionService.setRawKey(
                    key,
                    on: keyProvider,
                    participantId: localIdentity,
                    index: Int32(keyIndex)
                )
                logger.info("Local E2EE key set (index \(keyIndex)) under participantId=\(localIdentity, privacy: .public) before camera publish")
            }

            // Set up MatrixRTC signaling and distribute the key **before**
            // publishing media. LiveKit begins encrypting the instant
            // `setCamera(enabled: true)` attaches the track; if frames reach
            // peers before our key does, their LiveKit frame cryptor
            // ratchets in the dark, blows through its `ratchetWindowSize`
            // (10) worth of failures, and calls `markInvalid()` on index 0
            // — poisoning the slot so our late-arriving key is rejected
            // even though the raw IKM is correct. The original ordering ran
            // this in a background Task racing `setCamera`, which is
            // exactly that bug.
            //
            // Order: power levels → member state (so peers see us) →
            // deliver key via Olm-encrypted to-device → THEN publish media.
            // Failures here are logged but non-fatal — a late key is still
            // better than no key.
            if let encryptionService {
                let bridge = self.widgetBridge
                let localKey = self.localEncryptionKey
                let keyIndex = self.localKeyIndex

                // Debug: log existing call member events to compare formats.
                await encryptionService.fetchCallMemberEvents()

                // 1. Try to fix power levels (only works if we're admin/mod).
                do {
                    try await encryptionService.enableCallPowerLevels()
                } catch {
                    logger.warning("Call power level setup failed: \(error.localizedDescription)")
                }

                // 2. Send call membership state event (after power levels).
                // Pass the widget bridge's membershipId UUID so the
                // state-event `membershipID` matches the `member.id`
                // field in our outbound encryption_keys payloads.
                do {
                    try await encryptionService.sendCallMemberEvent(
                        sfuServiceURL: sfuServiceURL,
                        membershipId: bridge?.membershipId
                    )
                } catch {
                    logger.warning("Call membership event failed: \(error.localizedDescription)")
                }

                // 3. Distribute the already-generated local key via the
                // widget bridge. The `messages` map for the
                // `send_to_device` action requires an explicit
                // `{ userId: [deviceId, ...] }` map of recipients, so we
                // parse it from the `org.matrix.msc3401.call.member`
                // state events already present on the room. The SDK
                // then Olm-encrypts the payload per-device.
                if self.isE2eeEnabled, let bridge, let localKey {
                    let targets = await encryptionService.fetchCallTargets()
                    self.callMembers = targets
                    logger.info("Distributing key to \(targets.count) remote user(s) BEFORE media publish")
                    do {
                        try await bridge.sendEncryptionKey(
                            localKey,
                            keyIndex: keyIndex,
                            toMembers: targets
                        )
                    } catch {
                        logger.warning("Widget-bridge key distribution failed: \(error.localizedDescription)")
                    }
                }
            }

            // Key is now installed locally and (best-effort) distributed to
            // any existing call participants. Safe to publish media.
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(enabled: true)

            isLocalCameraEnabled = true
            isLocalMicrophoneEnabled = true
            state = .connected
            videoTrackRevision += 1
        } catch {
            logger.error("Connect failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func disconnect() async {
        // Update UI state immediately — don't block on network I/O.
        state = .disconnected
        participants = []
        isLocalCameraEnabled = false
        isLocalMicrophoneEnabled = false
        localParticipantID = nil
        videoViewCache.removeAll()
        localEncryptionKey = nil
        localKeyIndex = 0
        callMembers = [:]

        // Tear down the widget bridge synchronously so its tasks can't race
        // with subsequent connects.
        widgetBridge?.shutdown()
        widgetBridge = nil

        // Network cleanup in background so the UI never beachballs.
        let service = encryptionService
        let livekitRoom = room
        Task.detached {
            try? await service?.removeCallMemberEvent()
            await livekitRoom.disconnect()
        }
    }

    public func toggleCamera() async throws {
        let enabled = !isLocalCameraEnabled
        try await room.localParticipant.setCamera(enabled: enabled)
        isLocalCameraEnabled = enabled
        if let localID = localParticipantID {
            videoViewCache.removeValue(forKey: localID)
        }
        videoTrackRevision += 1
    }

    public func toggleMicrophone() async throws {
        let enabled = !isLocalMicrophoneEnabled
        try await room.localParticipant.setMicrophone(enabled: enabled)
        isLocalMicrophoneEnabled = enabled
    }

    public func makeVideoView(for participantID: String) -> AnyView? {
        let isLocal = room.localParticipant.identity?.stringValue == participantID
        let participant: Participant? = isLocal
            ? room.localParticipant
            : room.remoteParticipants.values.first { $0.identity?.stringValue == participantID }

        guard let publication = participant?.videoTracks.first,
              !publication.isMuted,
              let track = publication.track as? VideoTrack
        else {
            videoViewCache.removeValue(forKey: participantID)
            return nil
        }

        // For remote tracks, verify the track is actually subscribed.
        if let remotePub = publication as? RemoteTrackPublication, !remotePub.isSubscribed {
            videoViewCache.removeValue(forKey: participantID)
            return nil
        }

        // Return the cached view if the underlying VideoTrack is unchanged,
        // preventing SwiftUI from tearing down and recreating the Metal renderer.
        let trackID = ObjectIdentifier(track)
        if let cached = videoViewCache[participantID], cached.trackObjectID == trackID {
            return cached.view
        }

        let view = AnyView(
            SwiftUIVideoView(track,
                             layoutMode: .fill,
                             mirrorMode: isLocal ? .mirror : .off)
        )
        videoViewCache[participantID] = (trackObjectID: trackID, view: view)
        return view
    }

    // MARK: - E2EE Key Redistribution

    /// Re-sends the local encryption key to a newly joined participant so they
    /// can decrypt our media. Routes through the widget bridge so the SDK
    /// Olm-encrypts the to-device payload.
    fileprivate func redistributeKey(to participantIdentity: String) {
        guard let key = localEncryptionKey, let bridge = widgetBridge else { return }

        // Parse "user:device" from the LiveKit identity
        // (format: `@userId:server:deviceId`). Element Call uses identities
        // like `@user:server:DEVICEID`.
        let components = participantIdentity.components(separatedBy: ":")
        guard components.count >= 3 else {
            logger.warning("Cannot parse participant identity for key redistribution: \(participantIdentity, privacy: .private)")
            return
        }
        let userId = components[0] + ":" + components[1]
        let deviceId = components.dropFirst(2).joined(separator: ":")
        let index = localKeyIndex

        Task {
            do {
                try await bridge.sendEncryptionKey(
                    key,
                    keyIndex: index,
                    toMembers: [userId: [deviceId]]
                )
                logger.info("Redistributed key to \(participantIdentity, privacy: .private)")
            } catch {
                logger.warning("Key redistribution failed for \(participantIdentity, privacy: .private): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Participant Sync

    /// Re-syncs the ``participants`` array from the room's remote participants.
    /// - Parameter trackChanged: When `true`, also bumps ``videoTrackRevision``
    ///   to trigger video view updates. Pass `false` for cosmetic-only changes
    ///   (e.g. speaking indicators) to avoid disrupting the video renderer.
    fileprivate func syncParticipants(trackChanged: Bool = false) {
        if trackChanged { videoTrackRevision += 1 }

        let newParticipants = room.remoteParticipants.values.map { participant in
            CallParticipant(
                id: participant.identity?.stringValue ?? participant.sid?.stringValue ?? UUID().uuidString,
                displayName: participant.name,
                isCameraEnabled: participant.isCameraEnabled(),
                isMicrophoneEnabled: participant.isMicrophoneEnabled(),
                isSpeaking: participant.isSpeaking
            )
        }

        // Prune video view cache for participants who have left.
        if trackChanged {
            let activeIDs = Set(newParticipants.map(\.id))
            for key in videoViewCache.keys where key != localParticipantID && !activeIDs.contains(key) {
                videoViewCache.removeValue(forKey: key)
            }
        }

        // Only write to the observed `participants` property when the array
        // actually changed. The LiveKit `didUpdateSpeakingParticipants`
        // callback fires continuously during active audio, and every write
        // to an `@Observable` property invalidates downstream SwiftUI views
        // regardless of value equality — which can push NSHostingView into
        // an unbounded "Update Constraints in Window" loop and crash.
        if participants != newParticipants {
            participants = newParticipants
        }
    }

    // MARK: - Delegate Bridge

    /// Bridges `RoomDelegate` callbacks — which arrive on an unspecified thread — onto
    /// the main actor so that `CallViewModel`'s `@Observable` state is always mutated
    /// safely.  The class is `@unchecked Sendable` because `viewModel` is a weak reference
    /// that is only read inside `Task { @MainActor in … }` blocks.
    private final class Delegate: RoomDelegate, @unchecked Sendable {
        weak var viewModel: CallViewModel?

        init(viewModel: CallViewModel) {
            self.viewModel = viewModel
        }

        func room(_ room: LiveKit.Room, didUpdateConnectionState connectionState: LiveKit.ConnectionState, from oldValue: LiveKit.ConnectionState) {
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                switch connectionState {
                case .connected:
                    if viewModel.state != .connected {
                        viewModel.state = .connected
                    }
                case .disconnected:
                    if viewModel.state == .connected {
                        viewModel.state = .disconnected
                    }
                case .reconnecting:
                    logger.info("Reconnecting…")
                default:
                    break
                }
            }
        }

        func room(_ room: LiveKit.Room, participantDidConnect participant: RemoteParticipant) {
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                let identityStr = participant.identity?.stringValue ?? "(none)"
                let sidStr = participant.sid?.stringValue ?? "(none)"
                logger.info("Remote participant connected: identity=\(identityStr, privacy: .public) sid=\(sidStr, privacy: .public) name=\(participant.name ?? "(none)", privacy: .public)")
                viewModel.syncParticipants(trackChanged: true)
                if viewModel.isE2eeEnabled, let identity = participant.identity?.stringValue {
                    viewModel.redistributeKey(to: identity)
                }
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                let identityStr = participant.identity?.stringValue ?? "(none)"
                let kind = publication.kind.rawValue
                logger.info("Subscribed to \(kind, privacy: .public) track from identity=\(identityStr, privacy: .public) trackSid=\(publication.sid, privacy: .public)")
                viewModel?.syncParticipants(trackChanged: true)
            }
        }

        func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants(trackChanged: true)
            }
        }

        func room(_ room: LiveKit.Room, didUpdateSpeakingParticipants participants: [Participant]) {
            Task { @MainActor [weak viewModel] in
                // Speaking state is cosmetic — don't bump videoTrackRevision
                // to avoid disrupting the video renderer.
                viewModel?.syncParticipants(trackChanged: false)
            }
        }

        func room(_ room: LiveKit.Room, localParticipant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.videoTrackRevision += 1
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants(trackChanged: true)
            }
        }
    }
}
