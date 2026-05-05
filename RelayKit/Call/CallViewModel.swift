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
    /// Periodic refresh of the `org.matrix.msc3401.call.member` state event so
    /// peers don't expire our membership while the call is in progress.
    /// Element Call's matrix-js-sdk `MatrixRTCSession` does the equivalent.
    @ObservationIgnored
    private var heartbeatTask: Task<Void, Never>?
    /// Interval at which the call-member event is re-sent. Our `expires`
    /// field is 4 hours; refreshing every 30 minutes keeps a generous
    /// safety margin against missed sends.
    private static let heartbeatInterval: Duration = .seconds(30 * 60)

    /// Creates a call view model without E2EE. Use ``init(encryptionContext:)``
    /// for encrypted calls that interoperate with Element Call.
    public init() {
        LiveKitLogBridgeInstaller.install()
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
        LiveKitLogBridgeInstaller.install()
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
                logger.info("[RTC]E2EE enabled (encrypted Matrix room)")
            } else {
                logger.info("[RTC]E2EE disabled (unencrypted Matrix room)")
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
            logger.info("[RTC]Connected with LiveKit identity: \(self.localParticipantID ?? "unknown", privacy: .public)")

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
                    logger.error("[RTC]Failed to create CallWidgetBridge: \(error.localizedDescription, privacy: .private)")
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
                    logger.warning("[RTC]LiveKit identity \(livekitIdentity, privacy: .public) != matrix identity \(localIdentity, privacy: .public) — frame encryption may misroute")
                }
                let keyIndex = self.localKeyIndex
                CallEncryptionService.setRawKey(
                    key,
                    on: keyProvider,
                    participantId: localIdentity,
                    index: Int32(keyIndex)
                )
                logger.info("[RTC]Local E2EE key set (index \(keyIndex)) under participantId=\(localIdentity, privacy: .public) before camera publish")
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

                // 1. Send call membership state event. Pass the widget
                // bridge's membershipId UUID so the state-event
                // `membershipID` matches the `member.id` field in our
                // outbound encryption_keys payloads. Power levels must
                // already permit this (set at room creation via
                // `MatrixService.callPowerLevels`); we no longer try to
                // mutate them at join time, matching Element Call.
                let membershipId = bridge?.membershipId
                do {
                    try await encryptionService.sendCallMemberEvent(
                        sfuServiceURL: sfuServiceURL,
                        membershipId: membershipId
                    )
                } catch {
                    logger.warning("[RTC]Call membership event failed: \(error.localizedDescription, privacy: .private)")
                }

                // 2. Start the membership heartbeat. matrix-js-sdk's
                // `MatrixRTCSession` re-sends roughly every `expires/2`;
                // we use a shorter interval to be safe against missed
                // sends. Cancelled in `disconnect()`.
                self.heartbeatTask = Self.startHeartbeat(
                    encryptionService: encryptionService,
                    sfuServiceURL: sfuServiceURL,
                    membershipId: membershipId
                )

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
                    logger.info("[RTC]Distributing key to \(targets.count) remote user(s) BEFORE media publish")
                    do {
                        try await bridge.sendEncryptionKey(
                            localKey,
                            keyIndex: keyIndex,
                            toMembers: targets
                        )
                    } catch {
                        logger.warning("[RTC]Widget-bridge key distribution failed: \(error.localizedDescription, privacy: .private)")
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
            logger.error("[RTC]Connect failed: \(error.localizedDescription, privacy: .private)")
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func disconnect() async {
        // Update UI state immediately — SwiftUI re-renders to the
        // disconnected state while the awaited cleanup runs.
        state = .disconnected
        participants = []
        isLocalCameraEnabled = false
        isLocalMicrophoneEnabled = false
        localParticipantID = nil
        videoViewCache.removeAll()
        localEncryptionKey = nil
        localKeyIndex = 0
        callMembers = [:]

        // Stop the heartbeat first so it can't race the leave event and
        // accidentally re-publish a fresh membership while we're tearing down.
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Tear down the widget bridge synchronously so its tasks can't race
        // with subsequent connects.
        widgetBridge?.shutdown()
        widgetBridge = nil

        // Proper cleanup: send the empty `m.call.member` content so peers
        // see us leave immediately (otherwise they wait up to `expires`
        // ms — 4 hours — before treating us as gone). Best-effort, capped
        // by a short timeout so the UI never beach-balls if the homeserver
        // is slow to respond.
        let service = encryptionService
        await Self.runWithTimeout(seconds: 2) {
            try? await service?.removeCallMemberEvent()
        }

        await room.disconnect()
    }

    /// Re-sends the call-member state event on a fixed interval until cancelled.
    /// Detached from `self` so the loop body has no actor hop.
    nonisolated private static func startHeartbeat(
        encryptionService: CallEncryptionService,
        sfuServiceURL: String,
        membershipId: String?
    ) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            // Local logger — the file-scope `logger` is inferred as
            // MainActor-isolated and isn't reachable from a detached task.
            let log = Logger(subsystem: "RelayKit", category: "Call")
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                } catch {
                    return  // cancelled
                }
                if Task.isCancelled { return }
                do {
                    try await encryptionService.sendCallMemberEvent(
                        sfuServiceURL: sfuServiceURL,
                        membershipId: membershipId
                    )
                    log.debug("[RTC]Heartbeat refreshed call.member state event")
                } catch {
                    log.warning("[RTC]Heartbeat refresh failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    /// Runs `work` and returns when it completes or after `seconds`,
    /// whichever comes first. The work continues in the background after
    /// the timeout; the caller just stops waiting.
    nonisolated private static func runWithTimeout(
        seconds: TimeInterval,
        _ work: @Sendable @escaping () async -> Void
    ) async {
        let workTask: Task<Void, Never> = Task.detached(priority: .userInitiated) {
            await work()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await workTask.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
            }
            await group.next()
            group.cancelAll()
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

    public func videoAspectRatio(for participantID: String) -> CGFloat? {
        let isLocal = room.localParticipant.identity?.stringValue == participantID
        let participant: Participant? = isLocal
            ? room.localParticipant
            : room.remoteParticipants.values.first { $0.identity?.stringValue == participantID }

        guard let publication = participant?.videoTracks.first,
              !publication.isMuted,
              let track = publication.track as? VideoTrack else {
            return nil
        }
        if let remotePub = publication as? RemoteTrackPublication, !remotePub.isSubscribed {
            return nil
        }
        guard let dim = track.dimensions, dim.height > 0 else { return nil }
        return CGFloat(dim.width) / CGFloat(dim.height)
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
            logger.warning("[RTC]Cannot parse participant identity for key redistribution: \(participantIdentity, privacy: .private)")
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
                logger.info("[RTC]Redistributed key to \(participantIdentity, privacy: .private)")
            } catch {
                logger.warning("[RTC]Key redistribution failed for \(participantIdentity, privacy: .private): \(error.localizedDescription, privacy: .private)")
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
    ///
    /// Also conforms to ``TrackDelegate`` so it can observe per-track
    /// dimension changes (e.g. a remote rotating their camera, simulcast
    /// layer changes). LiveKit's `RoomDelegate` does not surface those.
    private final class Delegate: NSObject, RoomDelegate, TrackDelegate, @unchecked Sendable {
        weak var viewModel: CallViewModel?

        init(viewModel: CallViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        /// Bumps `videoTrackRevision` whenever a track's dimensions change,
        /// so SwiftUI tiles re-read `videoAspectRatio(for:)`.
        func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
            Task { @MainActor [weak viewModel] in
                viewModel?.videoTrackRevision += 1
            }
        }

        /// Attaches `self` as a `TrackDelegate` on a publication's underlying
        /// video track if present. Multicast — safe to call repeatedly.
        func observeDimensions(of publication: TrackPublication?) {
            guard let videoTrack = publication?.track as? VideoTrack else { return }
            videoTrack.add(delegate: self)
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
                    logger.info("[RTC]Reconnecting…")
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
                logger.info("[RTC]Remote participant connected: identity=\(identityStr, privacy: .public) sid=\(sidStr, privacy: .public) name=\(participant.name ?? "(none)", privacy: .public)")
                viewModel.syncParticipants(trackChanged: true)
                if viewModel.isE2eeEnabled, let identity = participant.identity?.stringValue {
                    viewModel.redistributeKey(to: identity)
                }
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
            observeDimensions(of: publication)
            Task { @MainActor [weak viewModel] in
                let identityStr = participant.identity?.stringValue ?? "(none)"
                let kind = publication.kind.rawValue
                logger.info("[RTC]Subscribed to \(kind, privacy: .public) track from identity=\(identityStr, privacy: .public) trackSid=\(publication.sid, privacy: .public)")
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
            observeDimensions(of: publication)
            Task { @MainActor [weak viewModel] in
                viewModel?.videoTrackRevision += 1
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants(trackChanged: true)
            }
        }

        // First-frame indicator: dimensions become valid here, so bump
        // videoTrackRevision so aspect-ratio observers re-read.
        func room(_ room: LiveKit.Room, participant: RemoteParticipant, trackPublication: RemoteTrackPublication, didUpdateStreamState streamState: StreamState) {
            Task { @MainActor [weak viewModel] in
                viewModel?.videoTrackRevision += 1
            }
        }

        // A peer toggled their camera/mic. We need to refresh the participant
        // snapshot (so `isCameraEnabled` / `isMicrophoneEnabled` flip) AND
        // bump videoTrackRevision so the tile body re-evaluates and
        // `makeVideoView` returns nil for the muted track — which surfaces
        // the placeholder immediately instead of waiting for the next
        // unrelated sync.
        func room(_ room: LiveKit.Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants(trackChanged: true)
            }
        }

        // Track-removed events behave the same way for our UI: refresh
        // participant state and bump the revision so the placeholder shows.
        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants(trackChanged: true)
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants(trackChanged: true)
            }
        }

        func room(_ room: LiveKit.Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.videoTrackRevision += 1
            }
        }
    }
}
