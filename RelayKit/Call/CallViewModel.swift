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

    private let room = LiveKit.Room()
    private var delegate: Delegate?

    /// Cached video views keyed by participant ID, to avoid recreating
    /// `SwiftUIVideoView` on every SwiftUI re-render.  Each entry stores
    /// the `ObjectIdentifier` of the `VideoTrack` so the cache is
    /// invalidated when the underlying track actually changes.
    private var videoViewCache: [String: (trackObjectID: ObjectIdentifier, view: AnyView)] = [:]

    // MARK: - E2EE State

    /// The LiveKit key provider used for per-participant AES-GCM frame encryption.
    private var keyProvider: BaseKeyProvider?
    /// The local participant's current encryption key (raw 16 bytes).
    private var localEncryptionKey: Data?
    /// The current key index (0-255, wraps around on ratchet).
    private var localKeyIndex: Int = 0
    /// Service for distributing encryption keys via Matrix to-device messages.
    private var encryptionService: CallEncryptionService?
    /// The Matrix SDK room, used to obtain the timeline for key listening.
    private var matrixRoom: MatrixRustSDK.Room?
    /// Handle for the timeline key listener; retained to keep the subscription alive.
    private var keyListenerHandle: TaskHandle?

    /// Creates a call view model without E2EE. Use ``init(encryptionContext:)``
    /// for encrypted calls that interoperate with Element Call.
    public init() {
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
        /// The Matrix SDK room, used to obtain the timeline for listening to
        /// inbound encryption key state events. `nil` if unavailable.
        public let matrixRoom: MatrixRustSDK.Room?

        public init(homeserver: String, accessToken: String, userID: String, deviceID: String, roomID: String, matrixRoom: MatrixRustSDK.Room? = nil) {
            self.homeserver = homeserver
            self.accessToken = accessToken
            self.userID = userID
            self.deviceID = deviceID
            self.roomID = roomID
            self.matrixRoom = matrixRoom
        }
    }

    /// Creates a call view model with E2EE enabled, using AES-128-GCM frame
    /// encryption compatible with Element Call's MatrixRTC key exchange.
    public init(encryptionContext: EncryptionContext) {
        let delegate = Delegate(viewModel: self)
        self.delegate = delegate
        room.add(delegate: delegate)

        self.encryptionService = CallEncryptionService(
            homeserver: encryptionContext.homeserver,
            accessToken: encryptionContext.accessToken,
            userID: encryptionContext.userID,
            deviceID: encryptionContext.deviceID,
            roomID: encryptionContext.roomID
        )

        // Per-participant key provider: each participant has their own key.
        let provider = BaseKeyProvider(isSharedKey: false)
        self.keyProvider = provider
        self.matrixRoom = encryptionContext.matrixRoom
    }

    // MARK: - CallViewModelProtocol

    public func connect(url: String, token: String) async throws {
        state = .connecting
        do {
            let connectOpts = ConnectOptions(
                autoSubscribe: true,
                enableMicrophone: true
            )

            // Build RoomOptions — with E2EE if a key provider was configured.
            let encryptionOpts: EncryptionOptions? = keyProvider.map {
                EncryptionOptions(keyProvider: $0, encryptionType: .gcm)
            }
            let roomOpts = RoomOptions(
                defaultVideoPublishOptions: VideoPublishOptions(
                    preferredCodec: .vp8
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
            logger.info("Connected as \(self.localParticipantID ?? "unknown")")

            // Send MatrixRTC call membership state event so Element-X and other
            // MatrixRTC clients can discover our participation in this call.
            if let encryptionService {
                Task {
                    do {
                        try await encryptionService.sendCallMemberEvent(livekitURL: url)
                    } catch {
                        logger.warning("Call membership event failed: \(error.localizedDescription)")
                    }
                }
            }

            // Generate and distribute the local E2EE key before publishing tracks,
            // so that the first frames are already encrypted.
            if let keyProvider, let encryptionService {
                let key = CallEncryptionService.generateKey()
                localEncryptionKey = key

                let localIdentity = localParticipantID ?? encryptionService.userID
                CallEncryptionService.setRawKey(
                    key,
                    on: keyProvider,
                    participantId: localIdentity,
                    index: Int32(localKeyIndex)
                )
                logger.info("Local E2EE key set (index \(self.localKeyIndex))")

                // Distribute key via both transports (best-effort, don't block connect).
                Task {
                    do {
                        // 1. To-device messages (Element Call interop)
                        let members = try await encryptionService.fetchJoinedMembers()
                        if !members.isEmpty {
                            try await encryptionService.sendKey(key, keyIndex: localKeyIndex, to: members)
                        }
                    } catch {
                        logger.warning("To-device key distribution failed: \(error.localizedDescription)")
                    }

                    do {
                        // 2. Room state event (Relay-to-Relay interop)
                        try await encryptionService.sendKeyAsStateEvent(key, keyIndex: localKeyIndex)
                    } catch {
                        logger.warning("State event key distribution failed: \(error.localizedDescription)")
                    }
                }

                // Start listening for inbound encryption keys from other participants.
                if let timeline = try? await matrixRoom?.timeline() {
                    keyListenerHandle = await CallEncryptionService.startListeningForKeys(
                        timeline: timeline,
                        keyProvider: keyProvider,
                        localIdentity: localIdentity
                    )
                    logger.info("Started listening for inbound encryption keys")
                }
            }

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
        // Remove call membership state event so other clients know we've left.
        if let encryptionService {
            try? await encryptionService.removeCallMemberEvent()
        }

        await room.disconnect()
        state = .disconnected
        participants = []
        isLocalCameraEnabled = false
        isLocalMicrophoneEnabled = false
        localParticipantID = nil
        videoViewCache.removeAll()
        localEncryptionKey = nil
        localKeyIndex = 0
        keyListenerHandle = nil
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
    /// can decrypt our media.
    fileprivate func redistributeKey(to participantIdentity: String) {
        guard let key = localEncryptionKey, let encryptionService else { return }

        // Parse "user:device" from the LiveKit identity (format: @userId:server:deviceId)
        // Element Call uses identities like "@user:server:DEVICEID".
        let components = participantIdentity.components(separatedBy: ":")
        guard components.count >= 3 else {
            logger.warning("Cannot parse participant identity for key redistribution: \(participantIdentity, privacy: .private)")
            return
        }
        // Reconstruct userId as first two components, deviceId as remaining.
        let userId = components[0] + ":" + components[1]
        let deviceId = components.dropFirst(2).joined(separator: ":")

        Task {
            do {
                try await encryptionService.sendKey(key, keyIndex: localKeyIndex, to: [userId: [deviceId]])
                logger.info("Redistributed key (to-device) to \(participantIdentity, privacy: .private)")
            } catch {
                logger.warning("Key redistribution (to-device) failed for \(participantIdentity, privacy: .private): \(error.localizedDescription)")
            }

            // State event is idempotent (overwrites previous), so re-sending is cheap.
            do {
                try await encryptionService.sendKeyAsStateEvent(key, keyIndex: localKeyIndex)
            } catch {
                logger.warning("Key redistribution (state event) failed: \(error.localizedDescription)")
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

        participants = newParticipants
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
                viewModel.syncParticipants(trackChanged: true)
                if let identity = participant.identity?.stringValue {
                    viewModel.redistributeKey(to: identity)
                }
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

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants(trackChanged: true)
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
