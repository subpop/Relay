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

import AVFoundation
import Foundation
import LiveKit
import MatrixKit
import MatrixRTC
import SwiftUI

/// A concrete ``CallViewModelProtocol`` implementation backed by the LiveKit Swift SDK.
///
/// ``CallViewModel`` owns a `LiveKit.Room` instance and bridges its delegate callbacks
/// into ``@Observable`` state for SwiftUI consumption.
///
/// MatrixRTC signaling (membership publish/refresh/leave, SFU credentials, and
/// E2EE key distribution) is handled by the ``RTCCallSession`` passed at init —
/// our membership is published before this object is created (see
/// `RelayClient.prepareCall`), so `connect(url:token:sfuServiceURL:)` only
/// attaches to LiveKit, installs keys, and starts media.
///
/// The inner ``Delegate`` class implements `RoomDelegate` and dispatches all callbacks
/// onto the main actor via `Task { @MainActor in … }` so that UI state mutations are
/// always performed on the correct actor without requiring LiveKit itself to be
/// `@MainActor`-aware.
@Observable
@MainActor
final class CallViewModel: CallViewModelProtocol {
    private(set) var state: CallState = .idle
    private(set) var participants: [CallParticipant] = []
    private(set) var isLocalCameraEnabled: Bool = false
    private(set) var isLocalMicrophoneEnabled: Bool = false
    private(set) var localParticipantID: String?
    /// Human-readable label for the current step inside `.connecting`.
    /// Updated as the connect path moves through LiveKit attach, key
    /// install, key distribution, and media start. Cleared when the call
    /// reaches `.connected` or `.failed`.
    private(set) var connectingPhase: String?
    /// Incremented whenever video tracks change, triggering SwiftUI to
    /// re-evaluate `videoContent(for:)` and pick up new or removed tracks.
    private(set) var videoTrackRevision: UInt = 0

    /// Camera inputs available to the system, for the in-call picker.
    private(set) var availableCameras: [CameraDevice] = []
    /// The `uniqueID` of the camera currently in use, or `nil` before one is
    /// resolved.
    private(set) var selectedCameraID: String?

    /// Microphone inputs available to the system, for the in-call picker.
    private(set) var availableAudioInputs: [AudioInputDevice] = []
    /// The deviceId of the audio input currently in use.
    private(set) var selectedAudioInputID: String?

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

    // MARK: - Camera selection

    /// Maps `CameraDevice.id` (`AVCaptureDevice.uniqueID`) back to the SDK
    /// device so `selectCamera` can resolve a picked entry.
    @ObservationIgnored
    private var cameraDevicesByID: [String: AVCaptureDevice] = [:]
    /// UserDefaults key for the last-used camera, preferred on the next call.
    @ObservationIgnored
    private let selectedCameraDefaultsKey = "selectedCameraUniqueID"

    /// Maps `AudioInputDevice.id` (deviceId) to the SDK audio device so
    /// `selectAudioInput` can resolve a picked entry. Audio input selection is
    /// process-global via `AudioManager.shared`, not per-call.
    @ObservationIgnored
    private var audioInputsByID: [String: AudioDevice] = [:]
    /// UserDefaults key for the last-used microphone, preferred on the next call.
    @ObservationIgnored
    private let selectedAudioInputDefaultsKey = "selectedAudioInputDeviceID"

    // MARK: - E2EE State
    //
    // All of these are implementation details — no SwiftUI view reads
    // them. Marking them `@ObservationIgnored` keeps their writes out of
    // the observation registrar, which eliminates a class of stray
    // invalidations that otherwise pile up during call startup.

    /// The LiveKit key provider used for per-participant AES-GCM frame encryption.
    @ObservationIgnored
    private var keyProvider: BaseKeyProvider?
    /// `true` when the HKDF-SHA256 cryptor was successfully swapped in.
    /// `false` means we fell back to the default PBKDF2 provider and interop
    /// with Element Call will fail.
    @ObservationIgnored
    private var hkdfKeyProviderInstalled: Bool = false
    /// The local participant's current encryption key (raw 16 bytes).
    @ObservationIgnored
    private var localEncryptionKey: Data?
    /// The current key index (0-255, wraps around on ratchet).
    @ObservationIgnored
    private var localKeyIndex: Int = 0
    /// MatrixRTC signaling session. Owns membership refresh, credential
    /// exchange state, and the key distributor.
    @ObservationIgnored
    private let session: RTCCallSession
    /// Our published call membership, refreshed periodically while connected.
    @ObservationIgnored
    private var membership: CallMembership
    /// Delayed-leave event ID scheduled at join, cancelled on clean leave.
    @ObservationIgnored
    private var leaveDelayId: String?
    /// SFU credentials minted at join. `CallManager.startCall` passes these
    /// to `connect(url:token:sfuServiceURL:)`; the manual join form in
    /// `CallView` supplies its own.
    @ObservationIgnored
    let credentials: LiveKitCredentials
    /// Periodic refresh of our `m.call.member` state event so peers don't
    /// expire our membership while the call is in progress. Element Call's
    /// `MatrixRTCSession` does the equivalent.
    @ObservationIgnored
    private var heartbeatTask: Task<Void, Never>?
    /// Consumes inbound `io.element.call.encryption_keys` to-device messages
    /// and installs them in the key provider.
    @ObservationIgnored
    private var keyPumpTask: Task<Void, Never>?

    // MARK: - Live Captions

    private(set) var isCaptionsEnabled: Bool = false
    private(set) var captions: [String: String] = [:]

    /// Active caption transcribers keyed by participant identity. Created
    /// lazily when captions are turned on or a remote audio track is
    /// subscribed; torn down when captions are turned off, the participant
    /// leaves, or the call ends.
    @ObservationIgnored
    private var captionTranscribers: [String: CaptionTranscriber] = [:]
    /// The track sid each active transcriber is attached to, keyed by
    /// participant identity. Lets attach/detach distinguish "same live track"
    /// (a redundant attach) from "a different track for a reused identity"
    /// (a leave→rejoin), so identity reuse is handled correctly regardless of
    /// the order LiveKit delivers subscribe vs. unsubscribe/disconnect events.
    @ObservationIgnored
    private var captionTrackSids: [String: Track.Sid] = [:]

    /// Per-participant rolling caption state. `history` accumulates
    /// finalized utterances joined by spaces; `volatile` holds the
    /// in-progress utterance the speaker is currently saying. The
    /// display string is `history + " " + volatile`. New finals append
    /// to history and clear volatile.
    private struct CaptionState {
        var history: String = ""
        var volatile: String = ""

        var displayText: String {
            switch (history.isEmpty, volatile.isEmpty) {
            case (true, true): return ""
            case (true, false): return volatile
            case (false, true): return history
            case (false, false): return history + " " + volatile
            }
        }
    }
    @ObservationIgnored
    private var captionStates: [String: CaptionState] = [:]

    /// Per-participant idle fade timers. Reset on every caption update;
    /// fires only when no new text has arrived, so long sentences stay on
    /// screen as they're being spoken AND for a reasonable read-time after
    /// the speaker stops.
    @ObservationIgnored
    private var captionFadeTasks: [String: Task<Void, Never>] = [:]

    /// Per-participant volatile-update debounce timers. Volatile partials
    /// from `SpeechTranscriber` arrive every ~50–100 ms while a remote is
    /// speaking, and many of them revise the just-shown text. Coalescing
    /// rapid revisions into a single visual update inside a small window
    /// trades a fraction of a second of latency for far less visible
    /// "jumping" of in-progress text. Final results bypass this and apply
    /// immediately — they're authoritative.
    @ObservationIgnored
    private var captionVolatileDebounceTasks: [String: Task<Void, Never>] = [:]
    /// How long to wait before applying the latest volatile partial.
    /// 180 ms is short enough that the displayed text never feels stale
    /// to the speaker but long enough to absorb the typical rate of
    /// recognizer revisions.
    private static let captionVolatileDebounceDelay: Duration = .milliseconds(180)

    /// Reading-rate target for the idle caption fade. Netflix's English
    /// guideline is 17 characters per second for adult viewers; we round
    /// to 17 and add a small buffer so the last word doesn't disappear
    /// the instant the reader catches up. Used to size the fade delay
    /// adaptively so a long sentence stays on screen long enough to
    /// read while a single short word doesn't linger.
    private static let captionReadCharsPerSecond: Double = 17
    /// Floor for the idle fade — Netflix's minimum subtitle duration is
    /// 5⁄6 of a second (833 ms). Anything shorter is too quick to perceive.
    private static let captionMinHoldSeconds: Double = 5.0 / 6.0
    /// Ceiling for the idle fade — Netflix's maximum subtitle duration is
    /// 7 seconds. Beyond this the user has read the line and the screen
    /// should clear, even if the buffer is unusually long.
    private static let captionMaxHoldSeconds: Double = 7.0
    /// Cap on the history string per participant — beyond this we drop
    /// from the head, keeping only the most recent text. Sized for the
    /// 42-char × 2-line Netflix wrap (84 chars visible) plus a buffer
    /// so a recent-but-just-scrolled-off line is still in memory if a
    /// volatile revision needs it.
    private static let captionHistoryMaxChars: Int = 168

    /// Interval at which our call-member event is re-sent. Our `expires`
    /// field is 4 hours; refreshing every 30 minutes keeps a generous
    /// safety margin against missed sends.
    private static let heartbeatInterval: Duration = .seconds(30 * 60)

    /// The Matrix room ID for this call, used for signaling and log context.
    @ObservationIgnored
    private let roomID: String
    /// Local Matrix user/device IDs, for key-identity derivation and diagnostics.
    @ObservationIgnored
    private let localUserId: String
    @ObservationIgnored
    private let localDeviceId: String

    /// Whether this call uses LiveKit-level E2EE (GCM frame encryption).
    /// Mirrors the Matrix room's encryption state.
    private let isE2eeEnabled: Bool

    /// Creates a call view model for an already-joined call.
    ///
    /// - Parameters:
    ///   - session: The MatrixRTC signaling session.
    ///   - joined: The join result — our membership, SFU credentials, and
    ///     scheduled delayed-leave ID.
    ///   - roomId: The Matrix room ID string.
    ///   - isRoomEncrypted: Whether the Matrix room has encryption enabled.
    ///     When `true`, LiveKit-level GCM frame encryption + key exchange is enabled.
    ///   - localUserId: Our Matrix user ID, for key-identity derivation.
    ///   - localDeviceId: Our Matrix device ID, for key-identity derivation.
    init(
        session: RTCCallSession,
        joined: JoinedCall,
        roomId: String,
        isRoomEncrypted: Bool,
        localUserId: String,
        localDeviceId: String
    ) {
        LiveKitLogBridgeInstaller.install()
        self.session = session
        self.membership = joined.membership
        self.leaveDelayId = joined.leaveDelayId
        self.credentials = joined.credentials
        self.roomID = roomId
        self.isE2eeEnabled = isRoomEncrypted
        self.localUserId = localUserId
        self.localDeviceId = localDeviceId

        let delegate = Delegate(viewModel: self)
        self.delegate = delegate
        room.add(delegate: delegate)

        if isRoomEncrypted {
            // Per-participant key provider: each participant has their own key.
            // Match Element Call's MatrixKeyProvider configuration so the JS
            // LiveKit E2EE worker doesn't exhaust its ratchet window trying to
            // decrypt our frames. Swift BaseKeyProvider defaults are
            // ratchetWindowSize: 0, keyRingSize: 16; Element Call uses 10/256.
            //
            // Additionally: swap in an HKDF-SHA256-backed key provider. The
            // LiveKit Swift SDK's default path constructs the ObjC provider
            // with PBKDF2 (libwebrtc's default), but Element Call /
            // livekit-client JS derives the AES-GCM key with HKDF from the
            // same raw IKM — so the two sides produce different AES keys from
            // matching fingerprints, and every frame's auth tag fails on the
            // peer. See CallE2EE.makeHKDFKeyProvider for details.
            let result = CallE2EE.makeHKDFKeyProvider(
                ratchetWindowSize: 10,
                keyRingSize: 256
            )
            self.keyProvider = result.provider
            self.hkdfKeyProviderInstalled = result.hkdfInstalled
        }
    }

    // MARK: - CallViewModelProtocol

    func connect(url: String, token: String, sfuServiceURL: String = "") async throws {
        state = .connecting
        connectingPhase = "Joining call server…"
        ActivityLog.shared.log(
            category: .call, severity: .info, source: "CallViewModel",
            summary: "Connecting to call",
            detail: "E2EE: \(isE2eeEnabled ? "enabled" : "disabled")",
            roomId: roomID
        )
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
                let kdfDetail = hkdfKeyProviderInstalled
                    ? "HKDF-SHA256 key derivation active (Element Call interop path)."
                    : "WARNING: HKDF swap failed — using default PBKDF2. Element Call peers will produce different AES keys from the same IKM and frames will fail to decrypt."
                ActivityLog.shared.log(
                    category: .call, severity: hkdfKeyProviderInstalled ? .debug : .warning, source: "CallViewModel",
                    summary: "LiveKit E2EE enabled",
                    detail: "GCM frame encryption active. \(kdfDetail)",
                    roomId: roomID
                )
            } else {
                ActivityLog.shared.log(
                    category: .call, severity: .debug, source: "CallViewModel",
                    summary: "LiveKit E2EE disabled",
                    detail: "Unencrypted Matrix room — frames sent in the clear to the SFU.",
                    roomId: roomID
                )
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
            connectingPhase = "Preparing encryption…"
            localParticipantID = room.localParticipant.identity?.stringValue
            ActivityLog.shared.log(
                category: .call, severity: .debug, source: "CallViewModel",
                summary: "Connected to LiveKit",
                detail: "Local identity: \(localParticipantID ?? "unknown").",
                roomId: roomID
            )

            // CRITICAL: Register the local E2EE key in the keyProvider
            // BEFORE publishing any media tracks. LiveKit begins encrypting
            // frames the instant `setCamera(enabled: true)` attaches the
            // track, so if the key isn't installed yet the first batch of
            // frames is encrypted with nothing the remote peer can decrypt —
            // and the peer's video decoder stalls on that first undecodable
            // frame, resulting in perpetual black video.
            //
            // Key under the identity LiveKit assigned us (the JWT `sub`
            // claim). The cryptor routes frames to remote peers' decoders
            // using the *same* identity string LiveKit hands the SFU, so
            // registering under the matrix-shaped `<user>:<device>` silently
            // misroutes outbound frames on v2.
            if self.isE2eeEnabled, let keyProvider = self.keyProvider {
                let key = CallKeyDistributor.generateKey()
                self.localEncryptionKey = key
                // Diagnostic: warn when the LiveKit-assigned identity
                // doesn't match the legacy matrix shape
                // (`${sender}:${device_id}`). Normally the credential path
                // keeps us on a known shape and this is silent; if it fires
                // we've landed on the v2 hash identity — outbound frames
                // still route correctly (we key under the LiveKit identity),
                // but peers must compute the same identity from our
                // `m.call.member` event to install our key for inbound.
                let matrixSidIdentity = "\(localUserId):\(localDeviceId)"
                if let livekitIdentity = self.localParticipantID,
                    livekitIdentity != matrixSidIdentity {
                    ActivityLog.shared.log(
                        category: .call, severity: .debug, source: "CallViewModel",
                        summary: "LiveKit identity differs from legacy shape",
                        detail: "LiveKit: \(livekitIdentity), legacy: \(matrixSidIdentity)",
                        roomId: roomID
                    )
                }
                let keyIndex = self.localKeyIndex
                guard let livekitIdentity = self.localParticipantID, !livekitIdentity.isEmpty else {
                    ActivityLog.shared.log(
                        category: .call, severity: .error, source: "CallViewModel",
                        summary: "LiveKit assigned no local identity",
                        detail: "Cannot install local E2EE key; outbound frames will be undecodable.",
                        roomId: roomID
                    )
                    throw CallViewModelError.missingLocalParticipantIdentity
                }
                let setKeyFailure = CallE2EE.setRawKey(
                    key,
                    on: keyProvider,
                    participantId: livekitIdentity,
                    index: Int32(keyIndex)
                )
                let failureNote = setKeyFailure.map { " setRawKey failure: \($0)." } ?? ""
                ActivityLog.shared.log(
                    category: .call, severity: setKeyFailure == nil ? .debug : .error, source: "CallViewModel",
                    summary: "Local E2EE key installed",
                    detail: "Index: \(keyIndex), participantId: \(livekitIdentity). Frame cryptor will use this key for outbound frames before camera/mic publish.\(failureNote)",
                    roomId: roomID
                )
            }

            // Our membership was published at join time (before this view
            // model existed). Start the heartbeat so peers don't expire us,
            // and — for encrypted rooms — start consuming inbound keys and
            // distribute our key to current members BEFORE publishing media.
            // LiveKit begins encrypting the instant `setCamera(enabled:
            // true)` attaches the track; if frames reach peers before our
            // key does, their frame cryptor ratchets in the dark, blows
            // through its `ratchetWindowSize` (10) worth of failures, and
            // poisons the slot so our late-arriving key is rejected even
            // though the raw IKM is correct.
            connectingPhase = "Announcing presence to the room…"
            self.heartbeatTask = Self.startHeartbeat(
                session: session,
                roomId: roomID,
                membership: membership
            )

            if self.isE2eeEnabled, let keyProvider = self.keyProvider {
                // Inbound keys: install under the identity the sender's
                // distributor registered (hashed or legacy form). Our own
                // key also loops back through here — reinstalling identical
                // bytes under the same identity is a harmless no-op.
                let keyStream = await session.keys.keyUpdates()
                self.keyPumpTask = Task { [weak self] in
                    for await update in keyStream {
                        guard let self else { return }
                        guard update.roomId.value == self.roomID else { continue }
                        let failure = CallE2EE.setRawKey(
                            update.key.key,
                            on: keyProvider,
                            participantId: update.key.identity,
                            index: Int32(update.key.index)
                        )
                        if let failure {
                            ActivityLog.shared.log(
                                category: .call, severity: .warning, source: "CallViewModel",
                                summary: "Inbound E2EE key install failed",
                                detail: "Identity: \(update.key.identity), index: \(update.key.index). \(failure)",
                                roomId: self.roomID
                            )
                        }
                    }
                }
                // Pump decrypted to-device batches into the distributor's store.
                Task.detached { [session] in
                    await session.keys.pumpToDevice()
                }

                if let localKey = self.localEncryptionKey {
                    connectingPhase = "Distributing encryption keys…"
                    do {
                        let members = try await session.memberships(roomId: RoomId(unchecked: roomID))
                        let targetList = members.map(\.userId.value).sorted().joined(separator: ", ")
                        ActivityLog.shared.log(
                            category: .call, severity: .debug, source: "CallViewModel",
                            summary: "Distributing E2EE key to \(members.count) member(s) before media publish",
                            detail: "Recipients: \(targetList.isEmpty ? "(none)" : targetList).",
                            roomId: roomID
                        )
                        try await session.keys.distribute(
                            roomId: RoomId(unchecked: roomID),
                            memberships: members,
                            membershipID: membership.membershipID,
                            index: localKeyIndex,
                            key: localKey
                        )
                    } catch {
                        ActivityLog.shared.log(
                            category: .call, severity: .warning, source: "CallViewModel",
                            summary: "E2EE key distribution failed",
                            detail: "Peers will see `missing_key` and our media will appear as black tiles to them. Error: \(error.localizedDescription)",
                            roomId: roomID
                        )
                    }
                }
            }

            // Key is now installed locally and (best-effort) distributed to
            // any existing call participants. Safe to publish media.
            connectingPhase = "Starting camera & microphone…"
            await refreshCameras()
            // Prefer the last-used camera if it's still present; otherwise let
            // LiveKit pick the system default.
            if let saved = UserDefaults.standard.string(forKey: selectedCameraDefaultsKey),
                cameraDevicesByID[saved] != nil {
                selectedCameraID = saved
            }
            await refreshAudioInputs()
            // Prefer the last-used microphone if it's still present.
            if let savedAudio = UserDefaults.standard.string(forKey: selectedAudioInputDefaultsKey),
                let device = audioInputsByID[savedAudio] {
                AudioManager.shared.inputDevice = device
                selectedAudioInputID = savedAudio
            }
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(enabled: true, captureOptions: selectedCameraCaptureOptions())
            // Reflect whichever device actually started so the picker checkmark
            // is correct even when we defaulted.
            if selectedCameraID == nil { selectedCameraID = currentCameraDeviceID() }

            isLocalCameraEnabled = true
            isLocalMicrophoneEnabled = true
            state = .connected
            connectingPhase = nil
            videoTrackRevision += 1

            // Enumerate participants already in the room. LiveKit's
            // `participantDidConnect` only fires for peers who join AFTER
            // us; when we join an in-progress call the existing peers are
            // already in `room.remoteParticipants`, so without this sync
            // the UI would sit on "waiting for participants" and never show
            // them. (When we're the first to join this is a no-op and
            // later joiners arrive via the delegate.)
            syncParticipants(trackChanged: true)

            ActivityLog.shared.log(
                category: .call, severity: .info, source: "CallViewModel",
                summary: "Connected to call",
                detail: "Existing remote participants: \(room.remoteParticipants.count).",
                roomId: roomID
            )
        } catch {
            // The native WebRTC audio engine returns -9000
            // (kAudioEngineErrorInsufficientDevicePermission) when
            // microphone access is denied. The LiveKit SDK wraps this in a
            // generic message, so surface a clearer description instead.
            let message: String
            if error.localizedDescription.contains("-9000") {
                message = "Microphone access was denied. Grant access in System Settings › Privacy & Security."
            } else {
                message = error.localizedDescription
            }

            state = .failed(message)
            connectingPhase = nil
            ActivityLog.shared.log(
                category: .call, severity: .error, source: "CallViewModel",
                summary: "Call connection failed",
                detail: error.localizedDescription,
                roomId: roomID
            )
            throw error
        }
    }

    func disconnect() async {
        ActivityLog.shared.log(
            category: .call, severity: .info, source: "CallViewModel",
            summary: "Disconnected from call",
            roomId: roomID
        )
        // Update UI state immediately — SwiftUI re-renders to the
        // disconnected state while the awaited cleanup runs.
        state = .disconnected
        connectingPhase = nil
        participants = []
        isLocalCameraEnabled = false
        isLocalMicrophoneEnabled = false
        localParticipantID = nil
        videoViewCache.removeAll()
        localEncryptionKey = nil
        localKeyIndex = 0
        // Stop all captions before LiveKit unsubscribes the audio tracks
        // from under us — the renderers must be removed first.
        await stopAllCaptionTranscribers()
        isCaptionsEnabled = false

        // Stop the heartbeat first so it can't race the leave event and
        // accidentally re-publish a fresh membership while we're tearing down.
        heartbeatTask?.cancel()
        heartbeatTask = nil
        keyPumpTask?.cancel()
        keyPumpTask = nil

        // Proper cleanup: clear our `m.call.member` content so peers
        // see us leave immediately (otherwise they wait up to `expires`
        // ms — 4 hours — before treating us as gone). Best-effort, capped
        // by a short timeout so the UI never beach-balls if the homeserver
        // is slow to respond.
        let session = self.session
        let roomId = self.roomID
        let delayId = self.leaveDelayId
        await Self.runWithTimeout(seconds: 2) {
            try? await session.leave(roomId: RoomId(unchecked: roomId), delayId: delayId)
        }

        await room.disconnect()
    }

    /// Re-sends our call-member state event on a fixed interval until cancelled.
    /// Detached from `self` so the loop body has no actor hop.
    nonisolated private static func startHeartbeat(
        session: RTCCallSession,
        roomId: String,
        membership: CallMembership
    ) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                } catch {
                    return  // cancelled
                }
                if Task.isCancelled { return }
                do {
                    try await session.refresh(
                        roomId: RoomId(unchecked: roomId),
                        membership: membership
                    )
                } catch {
                    let description = error.localizedDescription
                    await MainActor.run {
                        ActivityLog.shared.log(
                            category: .call, severity: .warning, source: "CallViewModel",
                            summary: "Call membership heartbeat refresh failed",
                            detail: "Other participants may treat us as having left when our event expires. Error: \(description)",
                            roomId: roomId
                        )
                    }
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

    func toggleCamera() async throws {
        let enabled = !isLocalCameraEnabled
        try await room.localParticipant.setCamera(
            enabled: enabled,
            captureOptions: enabled ? selectedCameraCaptureOptions() : nil
        )
        isLocalCameraEnabled = enabled
        if enabled, selectedCameraID == nil { selectedCameraID = currentCameraDeviceID() }
        if let localID = localParticipantID {
            videoViewCache.removeValue(forKey: localID)
        }
        videoTrackRevision += 1
    }

    func refreshCameras() async {
        let devices = (try? await CameraCapturer.captureDevices()) ?? []
        var byID: [String: AVCaptureDevice] = [:]
        var list: [CameraDevice] = []
        for device in devices {
            byID[device.uniqueID] = device
            list.append(CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                kind: Self.cameraKind(for: device)
            ))
        }
        cameraDevicesByID = byID
        availableCameras = list
    }

    func selectCamera(_ device: CameraDevice) async throws {
        guard let avDevice = cameraDevicesByID[device.id] else { return }
        selectedCameraID = device.id
        UserDefaults.standard.set(device.id, forKey: selectedCameraDefaultsKey)
        // Switch the device on the capturer whenever one exists — even when the
        // camera is muted/off, LiveKit keeps the capturer around, so we must
        // retarget it now rather than relying on a later setCamera(enabled:)
        // (which unmutes the existing track and would keep the old device,
        // leaving the self-view out of sync with the menu). If no capturer
        // exists (track fully unpublished), the stored selection is applied on
        // the next enable via selectedCameraCaptureOptions().
        if let publication = room.localParticipant.localVideoTracks.first(where: { $0.source == .camera }),
            let track = publication.track as? LocalVideoTrack,
            let capturer = track.capturer as? CameraCapturer {
            let newOptions = capturer.options.copyWith(device: .value(avDevice as AVCaptureDevice?))
            _ = try await capturer.set(options: newOptions)
            if let localID = localParticipantID {
                videoViewCache.removeValue(forKey: localID)
            }
            videoTrackRevision += 1
        }
        ActivityLog.shared.log(
            category: .call, severity: .info, source: "CallViewModel",
            summary: "Camera input selected",
            detail: "Camera: \(device.name) [\(device.kind)]",
            roomId: roomID
        )
    }

    /// Capture options pinned to the selected device, or `nil` to let LiveKit
    /// use the system default.
    private func selectedCameraCaptureOptions() -> CameraCaptureOptions? {
        guard let id = selectedCameraID, let device = cameraDevicesByID[id] else { return nil }
        return CameraCaptureOptions(device: device)
    }

    /// The `uniqueID` of the camera the local video track is currently
    /// capturing from, if any.
    private func currentCameraDeviceID() -> String? {
        guard let publication = room.localParticipant.localVideoTracks.first(where: { $0.source == .camera }),
            let track = publication.track as? LocalVideoTrack,
            let capturer = track.capturer as? CameraCapturer else { return nil }
        return capturer.device?.uniqueID
    }

    private static func cameraKind(for device: AVCaptureDevice) -> CameraDevice.Kind {
        switch device.deviceType {
        case .builtInWideAngleCamera: return .builtIn
        case .continuityCamera: return .continuity
        case .external: return .external
        default: return .unknown
        }
    }

    func refreshAudioInputs() async {
        let devices = AudioManager.shared.inputDevices
        var byID: [String: AudioDevice] = [:]
        var list: [AudioInputDevice] = []
        var indexByName: [String: Int] = [:]
        for device in devices {
            byID[device.deviceId] = device
            if let idx = indexByName[device.name] {
                // Bluetooth inputs like AirPods register several CoreAudio
                // device objects under one name. Collapse them to a single
                // entry (matching System Settings); prefer the default
                // object's id as the representative so selecting it routes
                // correctly.
                if device.isDefault {
                    list[idx] = AudioInputDevice(id: device.deviceId, name: device.name)
                }
            } else {
                indexByName[device.name] = list.count
                list.append(AudioInputDevice(id: device.deviceId, name: device.name))
            }
        }
        audioInputsByID = byID
        availableAudioInputs = list
        // Reflect the active device as its deduped (by-name) representative so
        // the checkmark matches a list entry even when the live id was one of
        // the collapsed duplicates.
        let currentName = AudioManager.shared.inputDevice.name
        selectedAudioInputID = list.first(where: { $0.name == currentName })?.id
    }

    func selectAudioInput(_ device: AudioInputDevice) async throws {
        // Update the UI immediately, then do the actual switch off the main
        // actor: LiveKit's AudioManager retargets the audio device module
        // synchronously, which on Bluetooth rebuilds the whole engine and can
        // block for seconds. Only the deviceId (Sendable) crosses the
        // boundary — AudioDevice is a non-Sendable class.
        selectedAudioInputID = device.id
        UserDefaults.standard.set(device.id, forKey: selectedAudioInputDefaultsKey)
        let deviceId = device.id
        await Task.detached(priority: .userInitiated) {
            guard let avDevice = AudioManager.shared.inputDevices
                .first(where: { $0.deviceId == deviceId }) else { return }
            AudioManager.shared.inputDevice = avDevice
        }.value
        ActivityLog.shared.log(
            category: .call, severity: .info, source: "CallViewModel",
            summary: "Audio input selected",
            detail: "Microphone: \(device.name)",
            roomId: roomID
        )
    }

    func toggleMicrophone() async throws {
        let enabled = !isLocalMicrophoneEnabled
        try await room.localParticipant.setMicrophone(enabled: enabled)
        isLocalMicrophoneEnabled = enabled
    }

    // MARK: - Captions

    func setCaptionsEnabled(_ enabled: Bool) async {
        guard enabled != isCaptionsEnabled else { return }
        isCaptionsEnabled = enabled

        if enabled {
            // Attach to every currently-subscribed remote audio track. New
            // tracks subscribed after this point are picked up via the
            // didSubscribeTrack delegate callback.
            for participant in room.remoteParticipants.values {
                guard let identity = participant.identity?.stringValue else { continue }
                for publication in participant.audioTracks {
                    guard let track = publication.track as? RemoteAudioTrack else { continue }
                    await attachCaptionTranscriber(to: track, identity: identity, trackSid: publication.sid)
                }
            }
        } else {
            await stopAllCaptionTranscribers()
        }
    }

    /// Creates a `CaptionTranscriber` for `identity`, attaches it to `track`,
    /// and starts the analyzer in the background.
    ///
    /// If a transcriber already exists for this identity: when it's bound to
    /// the *same* track this is a redundant attach and is a no-op; when it's
    /// bound to a *different* track — a leave→rejoin that reuses the identity —
    /// the stale one is torn down first so the rejoined participant gets a
    /// fresh, running transcriber. Without this, the rejoin would hit the old
    /// early-return and get no captions.
    private func attachCaptionTranscriber(to track: RemoteAudioTrack, identity: String, trackSid: Track.Sid) async {
        if captionTranscribers[identity] != nil {
            if captionTrackSids[identity] == trackSid { return }
            await detachCaptionTranscriber(identity: identity)
        }
        let transcriber = CaptionTranscriber(
            participantId: identity,
            onUpdate: { [weak self] text, isFinal in
                Task { @MainActor [weak self] in
                    self?.applyCaption(participantId: identity, text: text, isFinal: isFinal)
                }
            },
            onLog: { [weak self] severity, summary, detail in
                Task { @MainActor [weak self] in
                    ActivityLog.shared.log(
                        category: .call, severity: severity, source: "CaptionTranscriber",
                        summary: summary, detail: detail, roomId: self?.roomID
                    )
                }
            }
        )
        captionTranscribers[identity] = transcriber
        captionTrackSids[identity] = trackSid
        track.add(audioRenderer: transcriber)
        Task {
            do {
                try await transcriber.start()
            } catch {
                ActivityLog.shared.log(
                    category: .call, severity: .warning, source: "CallViewModel",
                    summary: "Caption transcriber start failed",
                    detail: "Identity: \(identity). Error: \(error.localizedDescription)",
                    roomId: roomID
                )
            }
        }
    }

    /// Detaches and stops the transcriber (if any) for `identity` from every
    /// remote audio track that participant is publishing. Removes any cached
    /// caption text and cancels the fade timer.
    ///
    /// When `ifTrackSid` is supplied, the detach only happens if the active
    /// transcriber is bound to that track — so a late unsubscribe for an old
    /// track can't tear down a transcriber that already belongs to a newer
    /// track (a reused identity after a rejoin).
    private func detachCaptionTranscriber(identity: String, ifTrackSid: Track.Sid? = nil) async {
        if let ifTrackSid, captionTrackSids[identity] != ifTrackSid { return }
        guard let transcriber = captionTranscribers.removeValue(forKey: identity) else { return }
        captionTrackSids.removeValue(forKey: identity)
        for participant in room.remoteParticipants.values where participant.identity?.stringValue == identity {
            for publication in participant.audioTracks {
                if let track = publication.track as? RemoteAudioTrack {
                    track.remove(audioRenderer: transcriber)
                }
            }
        }
        await transcriber.stop()
        captionFadeTasks.removeValue(forKey: identity)?.cancel()
        captionVolatileDebounceTasks.removeValue(forKey: identity)?.cancel()
        captionStates.removeValue(forKey: identity)
        captions.removeValue(forKey: identity)
    }

    /// Tears down every active transcriber. Used by the captions toggle and
    /// by `disconnect()`.
    private func stopAllCaptionTranscribers() async {
        let identities = Array(captionTranscribers.keys)
        for identity in identities {
            await detachCaptionTranscriber(identity: identity)
        }
        captionTrackSids.removeAll()
        captions.removeAll()
        captionStates.removeAll()
        for task in captionFadeTasks.values { task.cancel() }
        captionFadeTasks.removeAll()
        for task in captionVolatileDebounceTasks.values { task.cancel() }
        captionVolatileDebounceTasks.removeAll()
    }

    /// Tears down the transcriber for `identity` only if that participant is no
    /// longer in the room. Used by `participantDidDisconnect` so a leave→rejoin
    /// that reuses the identity doesn't tear down the freshly-attached
    /// transcriber for the new session.
    private func detachCaptionTranscriberIfGone(identity: String) async {
        let stillPresent = room.remoteParticipants.values.contains {
            $0.identity?.stringValue == identity
        }
        guard !stillPresent else { return }
        await detachCaptionTranscriber(identity: identity)
    }

    /// Pushes a transcription update into the observable `captions` map. For
    /// volatile (non-final) results the text is updated continuously; for
    /// final results we additionally schedule a fade-out so a stale caption
    /// doesn't linger after the speaker stops.
    /// Entry point from `CaptionTranscriber`'s result stream. Debounces
    /// volatile updates so the displayed text revises at most once per
    /// debounce window; finals supersede pending volatiles and apply
    /// immediately.
    @MainActor
    private func applyCaption(participantId: String, text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Any new event supersedes a pending debounced volatile.
        captionVolatileDebounceTasks.removeValue(forKey: participantId)?.cancel()

        if isFinal {
            commitCaption(participantId: participantId, text: trimmed, isFinal: true)
            return
        }

        // Volatile — schedule a debounced commit. Subsequent volatile
        // updates within the window cancel and replace this one, so the
        // UI only sees the *latest* partial after the recognizer has
        // settled for at least the debounce delay.
        let delay = Self.captionVolatileDebounceDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.captionVolatileDebounceTasks.removeValue(forKey: participantId)
                self.commitCaption(participantId: participantId, text: trimmed, isFinal: false)
            }
        }
        captionVolatileDebounceTasks[participantId] = task
    }

    /// Applies a caption update to the rolling buffer + observable state.
    /// Called either directly (for finals) or via the debounce timer (for
    /// volatiles).
    @MainActor
    private func commitCaption(participantId: String, text: String, isFinal: Bool) {
        let trimmed = text

        // Speech content stays out of the log — record only the metadata so we
        // can verify the audio→speech pipeline without leaking captions.
        ActivityLog.shared.log(
            category: .call, severity: .debug, source: "CallViewModel",
            summary: "Caption update",
            detail: "Identity: \(participantId), isFinal: \(isFinal), chars: \(trimmed.count)",
            roomId: roomID
        )

        // Rolling-buffer model:
        // - Volatile result → replace `volatile`. The same utterance keeps
        //   being revised in place as the speaker continues.
        // - Final result → append to `history` (with a space separator)
        //   and clear `volatile` to make room for the next utterance.
        // - Cap history from the head so it can't grow unbounded.
        var state = captionStates[participantId] ?? CaptionState()
        if isFinal {
            if state.history.isEmpty {
                state.history = trimmed
            } else {
                state.history += " " + trimmed
            }
            if state.history.count > Self.captionHistoryMaxChars {
                state.history = String(state.history.suffix(Self.captionHistoryMaxChars))
            }
            state.volatile = ""
        } else {
            state.volatile = trimmed
        }
        captionStates[participantId] = state
        captions[participantId] = state.displayText

        // Idle-based fade with Netflix-style reading-rate scaling. Reset
        // on every update (volatile OR final). The hold time after the
        // speaker stops scales with how much text is on screen — a single
        // short word clears in ~1s, a packed 2-line block stays for ~5s,
        // and we never go below 5⁄6s or above 7s.
        captionFadeTasks[participantId]?.cancel()
        let displayChars = Double(state.displayText.count)
        let readSeconds = displayChars / Self.captionReadCharsPerSecond
        let holdSeconds = min(Self.captionMaxHoldSeconds,
                              max(Self.captionMinHoldSeconds, readSeconds))
        let delay = Duration.seconds(holdSeconds)
        captionFadeTasks[participantId] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.captions.removeValue(forKey: participantId)
                self.captionStates.removeValue(forKey: participantId)
                self.captionFadeTasks.removeValue(forKey: participantId)
            }
        }
    }

    func videoAspectRatio(for participantID: String) -> CGFloat? {
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

    func makeVideoView(for participantID: String) -> AnyView? {
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

    /// Re-sends the local encryption key to all current call members so a
    /// peer that just joined can decrypt our media.
    ///
    /// Re-fetches `m.call.member` state and broadcasts to everyone, matching
    /// Element Call's `RTCEncryptionManager` behaviour on membership changes —
    /// slightly inefficient (existing peers receive our key twice) but correct
    /// on both legacy and v2 identity paths.
    ///
    /// The `participantIdentity` parameter is only used for logging.
    fileprivate func redistributeKey(to participantIdentity: String) {
        guard let key = localEncryptionKey, isE2eeEnabled else { return }
        let index = localKeyIndex
        let session = self.session
        let roomId = self.roomID
        let memberID = self.membership.membershipID

        Task {
            do {
                let members = try await session.memberships(roomId: RoomId(unchecked: roomId))
                guard !members.isEmpty else { return }
                try await session.keys.distribute(
                    roomId: RoomId(unchecked: roomId),
                    memberships: members,
                    membershipID: memberID,
                    index: index,
                    key: key
                )
            } catch {
                await MainActor.run {
                    ActivityLog.shared.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "E2EE key redistribution failed",
                        detail: "Trigger: new participant \(participantIdentity). Error: \(error.localizedDescription)",
                        roomId: roomId
                    )
                }
            }
        }
    }

    /// Surfaces a call-membership failure to the Activity Log. The most
    /// common failure shape in the wild is M_FORBIDDEN because the room's
    /// `power_levels.events.org.matrix.msc3401.call.member` defaults to
    /// `state_default` (50) instead of being explicitly lowered to 0 — when
    /// hit, peers running Element Call / Element X have no Matrix-level
    /// record of us joining the call, so they never send us their E2EE key
    /// and our tiles stay black. Relay-created rooms set the override at
    /// creation; rooms created elsewhere may not.
    fileprivate func logCallMembershipFailure(_ error: Error, description: String) {
        let isPowerLevelDenial = description.contains("M_FORBIDDEN")
            && description.contains("org.matrix.msc3401.call.member")
            && description.contains("power")
        let summary = "Call membership state event rejected"
        let detail: String
        if isPowerLevelDenial {
            detail = "Homeserver returned M_FORBIDDEN: this room requires a higher power level to send `org.matrix.msc3401.call.member`. Ask a room admin to set its required power level to 0 (Relay-created rooms do this automatically). Without this event in room state, other participants can't send you E2EE keys and your tiles will stay black on encrypted calls. Raw error: \(description)"
        } else {
            detail = "Without a successful call membership state event, peers can't see you as a call participant and won't send you E2EE keys. Raw error: \(description)"
        }
        ActivityLog.shared.log(
            category: .call, severity: .error, source: "CallViewModel",
            summary: summary,
            detail: detail,
            roomId: roomID
        )
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
                    ActivityLog.shared.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "LiveKit connection disconnected",
                        detail: "Previous state: \(Self.describe(oldValue))",
                        roomId: viewModel.roomID
                    )
                case .reconnecting:
                    ActivityLog.shared.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "Call reconnecting",
                        roomId: viewModel.roomID
                    )
                default:
                    break
                }
            }
        }

        /// Fires when the SFU rejects the initial connection (auth, transport,
        /// codec negotiation). Distinct from `didDisconnectWithError`, which
        /// fires after a successful connect terminates.
        func room(_ room: LiveKit.Room, didFailToConnectWithError error: LiveKitError?) {
            let description = error?.localizedDescription ?? "no error reported"
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                ActivityLog.shared.log(
                    category: .call, severity: .error, source: "CallViewModel",
                    summary: "LiveKit connection rejected",
                    detail: description,
                    roomId: viewModel.roomID
                )
            }
        }

        /// Fires when an already-connected room disconnects, with an optional
        /// error explaining why. A `nil` error indicates a clean local
        /// disconnect; a non-nil error is the most useful signal we get when
        /// a call drops mid-session.
        func room(_ room: LiveKit.Room, didDisconnectWithError error: LiveKitError?) {
            let description = error?.localizedDescription
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                if let description {
                    ActivityLog.shared.log(
                        category: .call, severity: .error, source: "CallViewModel",
                        summary: "LiveKit connection lost",
                        detail: description,
                        roomId: viewModel.roomID
                    )
                } else {
                    ActivityLog.shared.log(
                        category: .call, severity: .debug, source: "CallViewModel",
                        summary: "LiveKit disconnected cleanly",
                        roomId: viewModel.roomID
                    )
                }
            }
        }

        /// Human-readable label for a `LiveKit.ConnectionState` enum value.
        /// Lives on the delegate so the activity-log detail strings stay
        /// stable across LiveKit SDK updates.
        nonisolated private static func describe(_ state: LiveKit.ConnectionState) -> String {
            switch state {
            case .connected: "connected"
            case .disconnected: "disconnected"
            case .reconnecting: "reconnecting"
            case .connecting: "connecting"
            case .disconnecting: "disconnecting"
            }
        }

        /// Human-readable label for a `LiveKit.Track.Kind`. The raw value is
        /// `Int`-backed (`audio=0`, `video=1`, `none=2`) which is useless in
        /// logs.
        nonisolated fileprivate static func describe(_ kind: Track.Kind) -> String {
            switch kind {
            case .audio: "audio"
            case .video: "video"
            case .none: "none"
            default: "unknown(\(kind.rawValue))"
            }
        }

        func room(_ room: LiveKit.Room, participantDidConnect participant: RemoteParticipant) {
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                let identityStr = participant.identity?.stringValue ?? "(none)"
                let sidStr = participant.sid?.stringValue ?? "(none)"
                let displayName = participant.name ?? "(none)"
                ActivityLog.shared.log(
                    category: .call, severity: .debug, source: "CallViewModel",
                    summary: "Remote participant connected",
                    detail: "Identity: \(identityStr), sid: \(sidStr), name: \(displayName)",
                    roomId: viewModel.roomID
                )
                viewModel.syncParticipants(trackChanged: true)
                if viewModel.isE2eeEnabled, let identity = participant.identity?.stringValue {
                    viewModel.redistributeKey(to: identity)
                }
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
            observeDimensions(of: publication)
            let identityStr = participant.identity?.stringValue ?? "(none)"
            let kind = Self.describe(publication.kind)
            let sid = publication.sid
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                ActivityLog.shared.log(
                    category: .call, severity: .debug, source: "CallViewModel",
                    summary: "Subscribed to remote \(kind) track",
                    detail: "Identity: \(identityStr), trackSid: \(sid)",
                    roomId: viewModel.roomID
                )
                viewModel.syncParticipants(trackChanged: true)
                if viewModel.isCaptionsEnabled,
                   let identity = participant.identity?.stringValue,
                   let track = publication.track as? RemoteAudioTrack {
                    await viewModel.attachCaptionTranscriber(to: track, identity: identity, trackSid: sid)
                }
            }
        }

        /// Fires when LiveKit can't subscribe to a remote track — the most
        /// common cause is firewall / NAT blocking the media path while
        /// signalling completes. This is the strongest signal for the
        /// "connected, no media" failure shape.
        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
            let identityStr = participant.identity?.stringValue ?? "(none)"
            let description = error.localizedDescription
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                ActivityLog.shared.log(
                    category: .call, severity: .error, source: "CallViewModel",
                    summary: "Failed to subscribe to remote track",
                    detail: "Identity: \(identityStr), trackSid: \(trackSid), error: \(description)",
                    roomId: viewModel.roomID
                )
            }
        }

        func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) {
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                let identityStr = participant.identity?.stringValue ?? "(none)"
                ActivityLog.shared.log(
                    category: .call, severity: .debug, source: "CallViewModel",
                    summary: "Remote participant disconnected",
                    detail: "Identity: \(identityStr)",
                    roomId: viewModel.roomID
                )
                await viewModel.detachCaptionTranscriberIfGone(identity: identityStr)
                viewModel.syncParticipants(trackChanged: true)
            }
        }

        func room(_ room: LiveKit.Room, didUpdateSpeakingParticipants participants: [Participant]) {
            Task { @MainActor [weak viewModel] in
                // Speaking state is cosmetic — don't bump videoTrackRevision
                // to avoid disrupting the video renderer.
                viewModel?.syncParticipants(trackChanged: false)
            }
        }

        func room(_ room: LiveKit.Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
            observeDimensions(of: publication)
            let kind = Self.describe(publication.kind)
            let sid = publication.sid
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                ActivityLog.shared.log(
                    category: .call, severity: .debug, source: "CallViewModel",
                    summary: "Published local \(kind) track",
                    detail: "trackSid: \(sid)",
                    roomId: viewModel.roomID
                )
                viewModel.videoTrackRevision += 1
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
            let identityStr = participant.identity?.stringValue ?? "(none)"
            let kind = Self.describe(publication.kind)
            let sid = publication.sid
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                ActivityLog.shared.log(
                    category: .call, severity: .debug, source: "CallViewModel",
                    summary: "Remote published \(kind) track",
                    detail: "Identity: \(identityStr), trackSid: \(sid)",
                    roomId: viewModel.roomID
                )
                viewModel.syncParticipants(trackChanged: true)
            }
        }

        /// Per-track LiveKit E2EE state transitions. Only fires when E2EE is
        /// enabled on the room. Normal lifecycle is `.new` → `.ok`. Any other
        /// terminal state (`.missing_key`, `.encryption_failed`,
        /// `.decryption_failed`, `.internal_error`) is the canonical signal
        /// for "connected but no media" on encrypted rooms — surface them
        /// loudly so users on Element-Call interop calls can see the
        /// cryptor failing without having to read os_log.
        func room(_ room: LiveKit.Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
            let stateLabel = state.toString()
            let trackSid = trackPublication.sid
            let trackKind = Self.describe(trackPublication.kind)
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                switch state {
                case .ok, .new, .key_ratcheted:
                    return
                case .missing_key:
                    ActivityLog.shared.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "E2EE missing key for \(trackKind) track",
                        detail: "trackSid: \(trackSid). Remote peer's encryption key hasn't been received yet or was rejected.",
                        roomId: viewModel.roomID
                    )
                case .encryption_failed, .decryption_failed, .internal_error:
                    ActivityLog.shared.log(
                        category: .call, severity: .error, source: "CallViewModel",
                        summary: "E2EE failure on \(trackKind) track",
                        detail: "State: \(stateLabel), trackSid: \(trackSid)",
                        roomId: viewModel.roomID
                    )
                @unknown default:
                    return
                }
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
            let sid = publication.sid
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                if let identity = participant.identity?.stringValue {
                    await viewModel.detachCaptionTranscriber(identity: identity, ifTrackSid: sid)
                }
                viewModel.syncParticipants(trackChanged: true)
            }
        }

        func room(_ room: LiveKit.Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.videoTrackRevision += 1
            }
        }
    }
}

// MARK: - Errors

/// Errors raised by `CallViewModel.connect`. Only the cases that surface to
/// the user via the error reporter or the call sheet need a
/// `LocalizedError`; internal-only failures can be plain `Swift.Error`.
enum CallViewModelError: LocalizedError {
    case missingLocalParticipantIdentity

    var errorDescription: String? {
        switch self {
        case .missingLocalParticipantIdentity:
            return "LiveKit didn't assign an identity to the local participant; "
                + "the call can't be encrypted. Try reconnecting."
        }
    }
}
