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
import SwiftUI

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
    /// Human-readable label for the current step inside `.connecting`.
    /// Updated as the connect path moves through credential exchange,
    /// LiveKit attach, membership publish, key distribution, and media
    /// start. Cleared when the call reaches `.connected` or `.failed`.
    public private(set) var connectingPhase: String?
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
    /// `true` when the HKDF-SHA256 LKRTCFrameCryptorKeyProvider was
    /// successfully swapped in. `false` means we fell back to the
    /// default PBKDF2 provider and interop with Element Call will fail.
    @ObservationIgnored
    private var hkdfKeyProviderInstalled: Bool = false
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

    // MARK: - Live Captions

    public private(set) var isCaptionsEnabled: Bool = false
    public private(set) var captions: [String: String] = [:]

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
    /// fires only when no new text has arrived for ``captionIdleFadeDelay``,
    /// so long sentences stay on screen as they're being spoken AND for a
    /// reasonable read-time after the speaker stops.
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
    /// Interval at which the call-member event is re-sent. Our `expires`
    /// field is 4 hours; refreshing every 30 minutes keeps a generous
    /// safety margin against missed sends.
    private static let heartbeatInterval: Duration = .seconds(30 * 60)

    /// The Matrix room ID for this call, used for activity log context.
    @ObservationIgnored
    private var roomID: String?
    /// Activity log for surfacing call lifecycle events in the Activity Log window.
    @ObservationIgnored
    weak var activityLog: ActivityLog? {
        didSet { encryptionService?.activityLog = activityLog }
    }

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

        self.roomID = encryptionContext.roomID

        self.encryptionService = CallEncryptionService(
            homeserver: encryptionContext.homeserver,
            accessToken: encryptionContext.accessToken,
            userID: encryptionContext.userID,
            deviceID: encryptionContext.deviceID,
            roomID: encryptionContext.roomID,
            sdkRoom: encryptionContext.matrixRoom,
            activityLog: nil  // Set after activityLog is wired by MatrixService
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
            let result = CallEncryptionService.makeHKDFKeyProvider(
                ratchetWindowSize: 10,
                keyRingSize: 256
            )
            self.keyProvider = result.provider
            self.hkdfKeyProviderInstalled = result.hkdfInstalled
        }
        self.matrixRoom = encryptionContext.matrixRoom
    }

    // MARK: - CallViewModelProtocol

    public func connect(url: String, token: String, sfuServiceURL: String = "") async throws {
        state = .connecting
        connectingPhase = "Joining call server…"
        activityLog?.log(
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
                activityLog?.log(
                    category: .call, severity: hkdfKeyProviderInstalled ? .debug : .warning, source: "CallViewModel",
                    summary: "LiveKit E2EE enabled",
                    detail: "GCM frame encryption active. \(kdfDetail)",
                    roomId: roomID
                )
            } else {
                activityLog?.log(
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
            activityLog?.log(
                category: .call, severity: .debug, source: "CallViewModel",
                summary: "Connected to LiveKit",
                detail: "Local identity: \(localParticipantID ?? "unknown"). Peers reading our `m.call.member` event expect this to match `${sender}:${device_id}` for legacy session events.",
                roomId: roomID
            )

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
                    bridge.activityLog = self.activityLog
                    bridge.onCallMemberStateChanged = { [weak self] in
                        self?.redistributeKeyOnMembershipChange()
                    }
                    bridge.start()
                    self.widgetBridge = bridge
                } catch {
                    activityLog?.log(
                        category: .call, severity: .error, source: "CallViewModel",
                        summary: "Failed to create CallWidgetBridge",
                        detail: "E2EE key exchange will not work; remote tiles will stay black. Error: \(error.localizedDescription)",
                        roomId: roomID
                    )
                }
            }

            // CRITICAL: Register the local E2EE key in the keyProvider
            // BEFORE publishing any media tracks. LiveKit begins encrypting
            // frames the instant `setCamera(enabled: true)` attaches the
            // track, so if the key isn't installed yet the first batch of
            // frames is encrypted with nothing the remote peer can decrypt —
            // and Element-X's video decoder stalls on that first undecodable
            // frame, resulting in perpetual black video.
            //
            // Key under the identity LiveKit assigned us. This was the JWT
            // `sub` claim: `<user>:<server>:<device>` on the legacy
            // `/sfu/get` path, or the unpadded-base64 SHA-256 hash of
            // `[user, device, member_id]` on v2 `/get_token`. The cryptor
            // routes frames to remote peers' decoders using the *same*
            // identity string LiveKit hands the SFU, so registering under
            // the matrix-shaped `<user>:<device>` silently misroutes
            // outbound frames on v2.
            if self.isE2eeEnabled, let keyProvider = self.keyProvider {
                let key = CallEncryptionService.generateKey()
                self.localEncryptionKey = key
                // Diagnostic: warn when the LiveKit-assigned identity
                // doesn't match what peers will compute from our
                // session-kind `m.call.member` event
                // (`${sender}:${device_id}`, per matrix-js-sdk
                // `CallMembership.parseFromEvent`). The legacy-first
                // credential path keeps us on the colon shape, so this
                // is normally silent; if it fires we've landed on the
                // v2 hash identity and peer-side decryption will fail
                // until we also publish MSC4143 sticky events.
                let matrixSidIdentity: String? = encryptionService.map { "\($0.userID):\($0.deviceID)" }
                if let livekitIdentity = self.localParticipantID,
                   let matrixSidIdentity,
                   livekitIdentity != matrixSidIdentity {
                    activityLog?.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "LiveKit identity mismatch — frame encryption may misroute",
                        detail: "LiveKit: \(livekitIdentity), peers expect: \(matrixSidIdentity)",
                        roomId: roomID
                    )
                }
                let keyIndex = self.localKeyIndex
                guard let livekitIdentity = self.localParticipantID, !livekitIdentity.isEmpty else {
                    activityLog?.log(
                        category: .call, severity: .error, source: "CallViewModel",
                        summary: "LiveKit assigned no local identity",
                        detail: "Cannot install local E2EE key; outbound frames will be undecodable.",
                        roomId: roomID
                    )
                    throw CallViewModelError.missingLocalParticipantIdentity
                }
                let setKeyFailure = CallEncryptionService.setRawKey(
                    key,
                    on: keyProvider,
                    participantId: livekitIdentity,
                    index: Int32(keyIndex)
                )
                let failureNote = setKeyFailure.map { " setRawKey failure: \($0)." } ?? ""
                activityLog?.log(
                    category: .call, severity: setKeyFailure == nil ? .debug : .error, source: "CallViewModel",
                    summary: "Local E2EE key installed",
                    detail: "Index: \(keyIndex), participantId: \(livekitIdentity). Frame cryptor will use this key for outbound frames before camera/mic publish.\(failureNote)",
                    roomId: roomID
                )
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
                connectingPhase = "Announcing presence to the room…"
                do {
                    try await encryptionService.sendCallMemberEvent(
                        sfuServiceURL: sfuServiceURL,
                        membershipId: membershipId
                    )
                } catch {
                    let description = String(reflecting: error)
                    self.logCallMembershipFailure(error, description: description)
                }

                // 2. Start the membership heartbeat. matrix-js-sdk's
                // `MatrixRTCSession` re-sends roughly every `expires/2`;
                // we use a shorter interval to be safe against missed
                // sends. Cancelled in `disconnect()`.
                self.heartbeatTask = Self.startHeartbeat(
                    encryptionService: encryptionService,
                    sfuServiceURL: sfuServiceURL,
                    membershipId: membershipId,
                    activityLog: self.activityLog,
                    roomID: self.roomID
                )

                // 3. Distribute the already-generated local key via the
                // widget bridge. The `messages` map for the
                // `send_to_device` action requires an explicit
                // `{ userId: [deviceId, ...] }` map of recipients, so we
                // parse it from the `org.matrix.msc3401.call.member`
                // state events already present on the room. The SDK
                // then Olm-encrypts the payload per-device.
                if self.isE2eeEnabled, let bridge, let localKey {
                    connectingPhase = "Distributing encryption keys…"
                    let targets = await encryptionService.fetchCallTargets()
                    self.callMembers = targets
                    let targetList = targets.keys.sorted().joined(separator: ", ")
                    activityLog?.log(
                        category: .call, severity: .debug, source: "CallViewModel",
                        summary: "Distributing E2EE key to \(targets.count) user(s) before media publish",
                        detail: "Recipients: \(targetList.isEmpty ? "(none)" : targetList).",
                        roomId: roomID
                    )
                    do {
                        try await bridge.sendEncryptionKey(
                            localKey,
                            keyIndex: keyIndex,
                            toMembers: targets
                        )
                        // Success entry — including fp — already written by
                        // CallWidgetBridge.sendEncryptionKey.
                    } catch {
                        activityLog?.log(
                            category: .call, severity: .warning, source: "CallViewModel",
                            summary: "E2EE key distribution failed",
                            detail: "Tried sending to \(targets.count) user(s): \(targetList). Peers will see `missing_key` and our media will appear as black tiles to them. Error: \(error.localizedDescription)",
                            roomId: roomID
                        )
                    }
                }
            }

            // Key is now installed locally and (best-effort) distributed to
            // any existing call participants. Safe to publish media.
            connectingPhase = "Starting camera & microphone…"
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(enabled: true)

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
            // Existing peers won't fire `participantDidConnect`, so push our
            // key to them explicitly — mirrors the redistribute we'd
            // otherwise do on their join.
            if isE2eeEnabled {
                for participant in room.remoteParticipants.values {
                    if let identity = participant.identity?.stringValue {
                        redistributeKey(to: identity)
                    }
                }
            }

            activityLog?.log(
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
                message = "Microphone access was denied. Grant access in System Settings \u{203A} Privacy & Security."
            } else {
                message = error.localizedDescription
            }

            state = .failed(message)
            connectingPhase = nil
            activityLog?.log(
                category: .call, severity: .error, source: "CallViewModel",
                summary: "Call connection failed",
                detail: error.localizedDescription,
                roomId: roomID
            )
            throw error
        }
    }

    public func disconnect() async {
        activityLog?.log(
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
        callMembers = [:]

        // Stop the heartbeat first so it can't race the leave event and
        // accidentally re-publish a fresh membership while we're tearing down.
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Stop all captions before LiveKit unsubscribes the audio tracks
        // from under us — the renderers must be removed first.
        await stopAllCaptionTranscribers()
        isCaptionsEnabled = false

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
        membershipId: String?,
        activityLog: ActivityLog?,
        roomID: String?
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
                    try await encryptionService.sendCallMemberEvent(
                        sfuServiceURL: sfuServiceURL,
                        membershipId: membershipId
                    )
                    // Success entry already written by
                    // `CallEncryptionService.sendCallMemberEvent`.
                } catch {
                    let description = error.localizedDescription
                    await MainActor.run {
                        activityLog?.log(
                            category: .call, severity: .warning, source: "CallViewModel",
                            summary: "Call membership heartbeat refresh failed",
                            detail: "Other participants may treat us as having left when our event expires. Error: \(description)",
                            roomId: roomID
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

    // MARK: - Captions

    public func setCaptionsEnabled(_ enabled: Bool) async {
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
                    self?.activityLog?.log(
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
                activityLog?.log(
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
    /// volatiles). Same logic that used to live inline in `applyCaption`.
    @MainActor
    private func commitCaption(participantId: String, text: String, isFinal: Bool) {
        let trimmed = text

        // Speech content stays out of the log — record only the metadata so we
        // can verify the audio→speech pipeline without leaking captions.
        activityLog?.log(
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

    /// Re-sends the local encryption key to all current call members so a
    /// peer that just joined LiveKit can decrypt our media.
    ///
    /// Previously this method parsed the LiveKit participant identity
    /// (`@user:server:device`) to recover a single user/device target. On
    /// v2 the identity is an opaque base64 hash, so the parse fails and the
    /// new peer never receives our key. Re-fetching `m.call.member` state
    /// and broadcasting to everyone matches Element Call's
    /// `RTCEncryptionManager` behaviour on membership changes — slightly
    /// inefficient (existing peers receive our key twice) but correct on
    /// both legacy and v2 paths.
    ///
    /// The `participantIdentity` parameter is now only used for logging.
    /// Surfaces a `sendCallMemberEvent` failure to the Activity Log. The most
    /// common failure shape in the wild is M_FORBIDDEN because the room's
    /// `power_levels.events.org.matrix.msc3401.call.member` defaults to
    /// `state_default` (50) instead of being explicitly lowered to 0 — when
    /// hit, peers running Element Call / Element X have no Matrix-level
    /// record of us joining the call, so they never send us their E2EE key
    /// and our tiles stay black. Relay-created rooms set the override at
    /// creation (see `MatrixService.callPowerLevels`); rooms created
    /// elsewhere may not.
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
        activityLog?.log(
            category: .call, severity: .error, source: "CallViewModel",
            summary: summary,
            detail: detail,
            roomId: roomID
        )
    }

    /// Re-distributes our local E2EE key in response to an inbound
    /// `m.call.member` state change. The widget bridge fires the
    /// callback whenever it sees one of these events; we use that as a
    /// signal to refresh our recipient set, because the SDK's
    /// `RoomInfo.activeRoomCallParticipants` accessor lags behind
    /// LiveKit's `participantDidConnect` (which is what
    /// ``redistributeKey(to:)`` keys off).
    ///
    /// Guarded against heartbeat refreshes: skips when the *user* set
    /// of targets hasn't changed since the last send.
    fileprivate func redistributeKeyOnMembershipChange() {
        guard let key = localEncryptionKey,
              let bridge = widgetBridge,
              let encryptionService else {
            return
        }
        let index = localKeyIndex

        Task { [weak self] in
            guard let self else { return }
            let targets = await encryptionService.fetchCallTargets()
            let targetUserIDs = Set(targets.keys)
            let previousUserIDs = await MainActor.run { Set(self.callMembers.keys) }
            // Heartbeat / unchanged-member case: no new peer, nothing to do.
            if targetUserIDs.isEmpty || targetUserIDs == previousUserIDs { return }

            let targetList = targets.keys.sorted().joined(separator: ", ")
            do {
                try await bridge.sendEncryptionKey(
                    key,
                    keyIndex: index,
                    toMembers: targets
                )
                await MainActor.run {
                    self.callMembers = targets
                    self.activityLog?.log(
                        category: .call, severity: .debug, source: "CallViewModel",
                        summary: "Redistributed E2EE key on m.call.member change",
                        detail: "Recipients: \(targetList). Index: \(index).",
                        roomId: self.roomID
                    )
                }
            } catch {
                let description = error.localizedDescription
                await MainActor.run {
                    self.activityLog?.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "E2EE key redistribution failed (m.call.member trigger)",
                        detail: "Targets: \(targetList). Error: \(description)",
                        roomId: self.roomID
                    )
                }
            }
        }
    }

    fileprivate func redistributeKey(to participantIdentity: String) {
        guard let key = localEncryptionKey,
              let bridge = widgetBridge,
              let encryptionService else {
            return
        }
        let index = localKeyIndex

        Task {
            let targets = await encryptionService.fetchCallTargets()
            guard !targets.isEmpty else {
                await MainActor.run {
                    activityLog?.log(
                        category: .call, severity: .debug, source: "CallViewModel",
                        summary: "No call targets to redistribute key to",
                        detail: "Trigger: new participant \(participantIdentity). `fetchCallTargets` returned an empty map.",
                        roomId: roomID
                    )
                }
                return
            }
            let targetList = targets.keys.sorted().joined(separator: ", ")
            do {
                try await bridge.sendEncryptionKey(
                    key,
                    keyIndex: index,
                    toMembers: targets
                )
                // Success entry — including fp — already written by
                // CallWidgetBridge.sendEncryptionKey.
            } catch {
                await MainActor.run {
                    activityLog?.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "E2EE key redistribution failed",
                        detail: "Trigger: new participant \(participantIdentity). Targets: \(targetList). Error: \(error.localizedDescription)",
                        roomId: roomID
                    )
                }
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
                    viewModel.activityLog?.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "LiveKit connection disconnected",
                        detail: "Previous state: \(Self.describe(oldValue))",
                        roomId: viewModel.roomID
                    )
                case .reconnecting:
                    viewModel.activityLog?.log(
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
                viewModel.activityLog?.log(
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
                    viewModel.activityLog?.log(
                        category: .call, severity: .error, source: "CallViewModel",
                        summary: "LiveKit connection lost",
                        detail: description,
                        roomId: viewModel.roomID
                    )
                } else {
                    viewModel.activityLog?.log(
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
                viewModel.activityLog?.log(
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
                viewModel.activityLog?.log(
                    category: .call, severity: .debug, source: "CallViewModel",
                    summary: "Subscribed to remote \(kind) track",
                    detail: "Identity: \(identityStr), trackSid: \(sid)",
                    roomId: viewModel.roomID
                )
                viewModel.syncParticipants(trackChanged: true)
                // Wire captions onto any new remote audio if captions are on.
                if viewModel.isCaptionsEnabled,
                   let identity = participant.identity?.stringValue,
                   let track = publication.track as? RemoteAudioTrack {
                    await viewModel.attachCaptionTranscriber(to: track, identity: identity, trackSid: publication.sid)
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
                viewModel.activityLog?.log(
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
                viewModel.activityLog?.log(
                    category: .call, severity: .debug, source: "CallViewModel",
                    summary: "Remote participant disconnected",
                    detail: "Identity: \(identityStr)",
                    roomId: viewModel.roomID
                )
                // Tear down captions in case didUnsubscribeTrack didn't fire
                // for this participant's audio on disconnect — but only if the
                // participant is actually gone, so a quick leave→rejoin that
                // reuses the identity doesn't kill the new session's captions.
                if let identity = participant.identity?.stringValue {
                    await viewModel.detachCaptionTranscriberIfGone(identity: identity)
                }
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

        func room(_ room: LiveKit.Room, localParticipant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
            observeDimensions(of: publication)
            let kind = Self.describe(publication.kind)
            let sid = publication.sid
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                viewModel.activityLog?.log(
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
                viewModel.activityLog?.log(
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
                    viewModel.activityLog?.log(
                        category: .call, severity: .warning, source: "CallViewModel",
                        summary: "E2EE missing key for \(trackKind) track",
                        detail: "trackSid: \(trackSid). Remote peer's encryption key hasn't been received yet or was rejected.",
                        roomId: viewModel.roomID
                    )
                case .encryption_failed, .decryption_failed, .internal_error:
                    viewModel.activityLog?.log(
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
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                viewModel.syncParticipants(trackChanged: true)
                // Tear down captions for this specific audio track if it had any.
                if let identity = participant.identity?.stringValue,
                   publication.kind == .audio {
                    await viewModel.detachCaptionTranscriber(identity: identity, ifTrackSid: publication.sid)
                }
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
