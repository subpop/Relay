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

// CallWidgetBridge.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import LiveKit
import MatrixRustSDK
import RelayInterface
import os

/// Headless widget-driver bridge for MatrixRTC E2EE.
///
/// Relay embeds LiveKit natively for media but needs the Matrix Widget Driver
/// to handle the MatrixRTC signaling and, crucially, Olm-encrypted to-device
/// delivery of `io.element.call.encryption_keys`. Element Call's web app
/// normally runs inside a WebView that speaks the Widget API (postMessage JSON)
/// to `WidgetDriverHandle`; we collapse the WebView out and speak the same
/// JSON protocol directly from Swift.
///
/// The SDK side (`WidgetDriver`) handles Olm session setup, m.room.encrypted
/// envelope encryption/decryption, and device discovery transparently. We just
/// emit `send_to_device` widget-API requests with `encrypted: true` and
/// receive decrypted payloads back on the recv channel.
///
/// ## Lifecycle
/// 1. `start()` kicks off two tasks: the driver's `run(...)` loop and our
///    JSON recv loop on the handle.
/// 2. The recv loop handles SDK-initiated requests (capabilities, notify,
///    incoming events) and dispatches responses to pending outbound requests.
/// 3. `awaitReady()` blocks until the capabilities handshake has completed.
/// 4. `sendEncryptionKey(...)` and `sendCallMemberState(...)` issue
///    fromWidget requests and await their responses.
/// 5. `shutdown()` cancels both tasks and fails any outstanding continuations.
public final class CallWidgetBridge: @unchecked Sendable {

    // MARK: - Configuration

    /// Element Call widget capability strings. These match the capabilities
    /// declared by the Element Call web app and approved server-side by
    /// `getElementCallRequiredPermissions` (which `CapabilitiesProvider`
    /// returns on the SDK side).
    private static let elementCallCapabilities: [String] = [
        "io.element.requires_client",
        "org.matrix.msc3819.send.to_device:io.element.call.encryption_keys",
        "org.matrix.msc3819.receive.to_device:io.element.call.encryption_keys",
        "org.matrix.msc2762.receive.state_event:org.matrix.msc3401.call.member",
        "org.matrix.msc2762.receive.state_event:m.room.member",
        "org.matrix.msc2762.receive.state_event:m.room.encryption",
        "org.matrix.msc4157.send.delayed_event",
        "org.matrix.msc4157.update_delayed_event"
    ]

    /// Supported matrix-widget-api versions we advertise to the SDK when it
    /// requests `supported_api_versions`. These match what Element Call's
    /// widget declares.
    private static let supportedApiVersions: [String] = [
        "0.0.1",
        "0.0.2"
    ]

    // MARK: - Properties

    private let widgetId: String
    private let ownUserId: String
    private let ownDeviceId: String
    private let roomId: String
    /// Activity log for surfacing widget bridge events in the Activity Log window.
    weak var activityLog: ActivityLog?
    /// Fires whenever an `org.matrix.msc3401.call.member` state event is
    /// observed via the widget driver — used by ``CallViewModel`` to retry
    /// E2EE key distribution after a peer's membership lands in room
    /// state. Closing on `[weak self]` is the caller's responsibility.
    var onCallMemberStateChanged: (() -> Void)?
    /// Per-call MatrixRTC membership UUID. Must match the `membershipID`
    /// field in the `org.matrix.msc3401.call.member` state event and the
    /// `member.id` field in outbound `io.element.call.encryption_keys`
    /// to-device payloads so peers can correlate our keys with our
    /// membership event.
    public let membershipId: String
    private weak var keyProvider: BaseKeyProvider?
    private let room: MatrixRustSDK.Room
    private let capabilitiesProvider: ElementCallCapabilitiesProvider

    private var driver: WidgetDriver?
    private var handle: WidgetDriverHandle?
    private var recvTask: Task<Void, Never>?
    private var driverTask: Task<Void, Never>?

    /// State that may be touched from the driver recv loop, the shutdown
    /// path, and outbound-request callers concurrently. Kept behind an
    /// unfair-lock so access is synchronous and async-context-safe.
    ///
    /// Pending requests resume with `Void` — callers fire and forget. If a
    /// future caller needs the response body, wire a separate sink.
    private struct State {
        var pendingRequests: [String: CheckedContinuation<Void, Error>] = [:]
        var readyContinuations: [CheckedContinuation<Void, Never>] = []
        var isReady: Bool = false
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    // MARK: - Init / Start / Shutdown

    /// Creates a bridge for the given Matrix room.
    ///
    /// - Parameters:
    ///   - room: The SDK room hosting the call.
    ///   - ownUserId: Local user's Matrix ID (e.g. `@alice:server`).
    ///   - ownDeviceId: Local device ID.
    ///   - isRoomEncrypted: Whether the room is encrypted — controls the
    ///     `EncryptionSystem` on the widget settings.
    ///   - keyProvider: The LiveKit key provider that receives inbound keys.
    public init(
        room: MatrixRustSDK.Room,
        ownUserId: String,
        ownDeviceId: String,
        isRoomEncrypted: Bool,
        keyProvider: BaseKeyProvider?
    ) throws {
        self.room = room
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
        self.roomId = room.id()
        self.keyProvider = keyProvider
        self.widgetId = UUID().uuidString
        self.membershipId = UUID().uuidString.lowercased()
        self.capabilitiesProvider = ElementCallCapabilitiesProvider(
            ownUserId: ownUserId,
            ownDeviceId: ownDeviceId
        )

        let props = VirtualElementCallWidgetProperties(
            elementCallUrl: "https://call.element.io",
            widgetId: self.widgetId,
            parentUrl: nil,
            fontScale: nil,
            font: nil,
            encryption: isRoomEncrypted ? .perParticipantKeys : .unencrypted,
            posthogUserId: nil,
            posthogApiHost: nil,
            posthogApiKey: nil,
            rageshakeSubmitUrl: nil,
            sentryDsn: nil,
            sentryEnvironment: nil
        )

        let config = VirtualElementCallWidgetConfig(
            intent: .joinExisting,
            skipLobby: true,
            header: nil,
            hideHeader: true,
            preload: nil,
            appPrompt: false,
            confineToRoom: true,
            hideScreensharing: nil,
            controlledAudioDevices: true,
            sendNotificationType: nil
        )

        let settings = try newVirtualElementCallWidget(props: props, config: config)
        let driverAndHandle = try makeWidgetDriver(settings: settings)
        self.driver = driverAndHandle.driver
        self.handle = driverAndHandle.handle
    }

    /// Starts the driver and the recv loop. Idempotent.
    ///
    /// Element Call's virtual widget settings set `init_on_content_load: true`
    /// inside the Rust SDK, meaning the driver's state machine **waits for a
    /// `content_loaded` fromWidget request before it will do anything**
    /// (including capability negotiation). We fire that proactively so the
    /// driver progresses and eventually sends us the `capabilities` request.
    public func start() {
        guard let driver, let handle else { return }
        guard driverTask == nil, recvTask == nil else { return }

        let room = self.room
        let capabilitiesProvider = self.capabilitiesProvider
        driverTask = Task { [weak self] in
            await driver.run(room: room, capabilitiesProvider: capabilitiesProvider)
            guard let self else { return }
            await MainActor.run {
                self.activityLog?.log(
                    category: .call, severity: .debug, source: "CallWidgetBridge",
                    summary: "WidgetDriver.run returned (driver exited)",
                    roomId: self.roomId
                )
            }
            self.resolveReady()
        }

        recvTask = Task { [weak self] in
            await self?.recvLoop(handle: handle)
        }

        // Kick the state machine off the "Unset" state. Fire-and-forget —
        // the response just echoes back through recvLoop.
        Task { [weak self] in
            guard let self else { return }
            let widgetId = self.widgetId
            do {
                try await self.sendRequest(action: "content_loaded", data: [:])
                await MainActor.run {
                    self.activityLog?.log(
                        category: .call, severity: .debug, source: "CallWidgetBridge",
                        summary: "Widget content_loaded acknowledged by driver",
                        detail: "widgetId: \(widgetId)",
                        roomId: self.roomId
                    )
                }
            } catch {
                let description = error.localizedDescription
                await MainActor.run {
                    self.activityLog?.log(
                        category: .call, severity: .warning, source: "CallWidgetBridge",
                        summary: "content_loaded failed",
                        detail: "widgetId: \(widgetId). Error: \(description)",
                        roomId: self.roomId
                    )
                }
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activityLog?.log(
                category: .call, severity: .debug, source: "CallWidgetBridge",
                summary: "Widget bridge started",
                detail: "widgetId: \(self.widgetId)",
                roomId: self.roomId
            )
        }
    }

    /// Cancels both tasks and fails any outstanding pending requests.
    public func shutdown() {
        recvTask?.cancel()
        driverTask?.cancel()
        recvTask = nil
        driverTask = nil

        // Fail any pending outbound continuations so callers don't hang.
        let pending = state.withLock { s -> [CheckedContinuation<Void, Error>] in
            let values = Array(s.pendingRequests.values)
            s.pendingRequests.removeAll()
            return values
        }
        for cont in pending {
            cont.resume(throwing: CallWidgetBridgeError.shutdown)
        }

        resolveReady()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activityLog?.log(
                category: .call, severity: .debug, source: "CallWidgetBridge",
                summary: "Widget bridge shut down",
                roomId: self.roomId
            )
        }
    }

    /// Suspends until the capabilities handshake has completed and the
    /// widget is permitted to send state and to-device events.
    public func awaitReady() async {
        // Fast path: already ready.
        let alreadyReady = state.withLock { $0.isReady }
        if alreadyReady { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Re-check under the lock to avoid races with resolveReady().
            let shouldResume = state.withLock { s -> Bool in
                if s.isReady { return true }
                s.readyContinuations.append(cont)
                return false
            }
            if shouldResume { cont.resume() }
        }
    }

    private func resolveReady() {
        let toResume = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            if s.isReady { return [] }
            s.isReady = true
            let pending = s.readyContinuations
            s.readyContinuations.removeAll()
            return pending
        }
        for c in toResume { c.resume() }
    }

    // MARK: - Public API

    /// Sends an encrypted `io.element.call.encryption_keys` to-device message
    /// to the specified user/device map via a fromWidget `send_to_device`
    /// request. The SDK handles Olm encryption transparently.
    ///
    /// - Parameters:
    ///   - key: Raw 16-byte AES-128-GCM key.
    ///   - keyIndex: Key index (0–255).
    ///   - toMembers: Map of `userId -> [deviceId]`. Use `"*"` as device id
    ///     to target all devices of that user.
    public func sendEncryptionKey(
        _ key: Data,
        keyIndex: Int,
        toMembers: [String: [String]]
    ) async throws {
        await awaitReady()

        let base64Key = key.base64EncodedString()
        let sentTs = Int(Date().timeIntervalSince1970 * 1000)

        // Wire format per matrix-js-sdk
        // `EncryptionKeysToDeviceEventContent`:
        //   { keys: {index, key},                           // SINGLE object
        //     member: {id, claimed_device_id},              // id = membership UUID
        //     room_id,
        //     session: {application, call_id, scope},
        //     sent_ts? }
        // Element Call's parser discards payloads where `keys` is an
        // array or where `member`/`room_id`/`session` are missing — which
        // is why earlier calls completed key exchange yet peers never
        // decoded our frames.
        let content: [String: Any] = [
            "keys": [
                "index": keyIndex,
                "key": base64Key
            ] as [String: Any],
            "member": [
                "id": self.membershipId,
                "claimed_device_id": self.ownDeviceId
            ] as [String: Any],
            "room_id": self.roomId,
            "session": [
                "application": "m.call",
                "call_id": "",
                "scope": "m.room"
            ] as [String: Any],
            "sent_ts": sentTs
        ]

        var messages: [String: [String: Any]] = [:]
        for (userId, deviceIds) in toMembers {
            var deviceMessages: [String: Any] = [:]
            for deviceId in deviceIds {
                deviceMessages[deviceId] = content
            }
            messages[userId] = deviceMessages
        }

        let data: [String: Any] = [
            "type": CallEncryptionService.encryptionKeysEventType,
            "encrypted": true,
            "messages": messages
        ]

        // SHA-256 fingerprint of the raw IKM going on the wire. This is
        // compared against the fingerprint logged by `setRawKey` at the local
        // cryptor registration site. Matching prefixes confirm the same 16
        // bytes are both (a) driving our outgoing AES-128-GCM and (b) being
        // base64'd into this to-device payload. Diverging prefixes localise
        // the bug to the key-capture path in `CallViewModel.connect`.
        let fp = SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()

        _ = try await sendRequest(action: "send_to_device", data: data)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activityLog?.log(
                category: .call, severity: .debug, source: "CallWidgetBridge",
                summary: "Sent E2EE key to \(toMembers.count) user(s)",
                detail: "Key index: \(keyIndex), member.id: \(self.membershipId), sha256[0..8]: \(fp).",
                roomId: self.roomId
            )
        }
    }

    /// Sends a MatrixRTC call member state event
    /// (`org.matrix.msc3401.call.member`) via a fromWidget `send_event`
    /// request.
    public func sendCallMemberState(
        content: [String: Any],
        stateKey: String
    ) async throws {
        await awaitReady()

        let data: [String: Any] = [
            "type": CallEncryptionService.callMemberEventType,
            "state_key": stateKey,
            "content": content,
            "room_id": roomId
        ]

        _ = try await sendRequest(action: "send_event", data: data)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activityLog?.log(
                category: .call, severity: .debug, source: "CallWidgetBridge",
                summary: "Sent call member state event via widget",
                detail: "state_key: \(stateKey)",
                roomId: self.roomId
            )
        }
    }

    // MARK: - Request / Response plumbing

    /// Issues a fromWidget request and awaits acknowledgement. The response
    /// body is not surfaced — if a future call-site needs it, add a separate
    /// delivery channel keyed by `requestId`.
    private func sendRequest(action: String, data: [String: Any]) async throws {
        guard let handle else {
            throw CallWidgetBridgeError.notStarted
        }

        let requestId = UUID().uuidString
        let msg: [String: Any] = [
            "api": "fromWidget",
            "widgetId": widgetId,
            "requestId": requestId,
            "action": action,
            "data": data
        ]
        let json = try Self.encode(msg)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            state.withLock { $0.pendingRequests[requestId] = cont }

            Task {
                let ok = await handle.send(msg: json)
                if !ok {
                    let waiting = state.withLock { s -> CheckedContinuation<Void, Error>? in
                        s.pendingRequests.removeValue(forKey: requestId)
                    }
                    waiting?.resume(throwing: CallWidgetBridgeError.sendFailed)
                }
            }
        }
    }

    // MARK: - Recv loop

    private func recvLoop(handle: WidgetDriverHandle) async {
        while !Task.isCancelled {
            guard let raw = await handle.recv() else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activityLog?.log(
                        category: .call, severity: .info, source: "CallWidgetBridge",
                        summary: "Widget driver recv loop exited",
                        detail: "WidgetDriverHandle.recv returned nil.",
                        roomId: self.roomId
                    )
                }
                break
            }

            // SECURITY: never surface raw widget JSON. Outbound and inbound
            // `send_to_device` payloads of type `io.element.call.encryption_keys`
            // carry raw AES keys in the `keys.key` field — those would land
            // unredacted in any log sink. We track action / type only.

            guard let data = raw.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activityLog?.log(
                        category: .call, severity: .warning, source: "CallWidgetBridge",
                        summary: "Non-JSON message from widget driver",
                        detail: "Length: \(raw.count) bytes.",
                        roomId: self.roomId
                    )
                }
                continue
            }

            // Responses to our outbound fromWidget requests.
            if let api = msg["api"] as? String,
               api == "fromWidget",
               msg["response"] != nil,
               let requestId = msg["requestId"] as? String {
                let cont = state.withLock { s -> CheckedContinuation<Void, Error>? in
                    s.pendingRequests.removeValue(forKey: requestId)
                }
                let response = (msg["response"] as? [String: Any]) ?? [:]
                if let err = response["error"] as? [String: Any] {
                    let message = (err["message"] as? String) ?? "unknown"
                    cont?.resume(throwing: CallWidgetBridgeError.widgetError(message))
                } else {
                    cont?.resume(returning: ())
                }
                continue
            }

            // Incoming SDK-initiated requests (toWidget).
            guard let action = msg["action"] as? String else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activityLog?.log(
                        category: .call, severity: .warning, source: "CallWidgetBridge",
                        summary: "Widget message missing action",
                        detail: "Message has neither `response` nor `action` keys; ignoring.",
                        roomId: self.roomId
                    )
                }
                continue
            }
            let requestId = (msg["requestId"] as? String) ?? ""
            let reqData = (msg["data"] as? [String: Any]) ?? [:]

            await handleIncoming(action: action, requestId: requestId, data: reqData, fullMessage: msg, handle: handle)
        }
    }

    private func handleIncoming(
        action: String,
        requestId: String,
        data: [String: Any],
        fullMessage: [String: Any],
        handle: WidgetDriverHandle
    ) async {
        var responseBody: [String: Any] = [:]

        switch action {
        case "capabilities":
            // SDK is asking which capabilities we want. Replying here
            // concludes the first half of negotiation; the driver will then
            // call our `acquireCapabilities` provider to approve.
            responseBody = ["capabilities": Self.elementCallCapabilities]

        case "notify_capabilities":
            // SDK telling us what was approved. After this we're ready.
            responseBody = [:]
            resolveReady()

        case "supported_api_versions":
            responseBody = ["supported_versions": Self.supportedApiVersions]

        case "send_to_device":
            handleIncomingToDevice(data: data)
            responseBody = [:]

        case "send_event", "update_state":
            // Incoming Matrix events observed by the widget driver.
            // MatrixRTC member state is handled by Element Call peers
            // directly; we just need to ack these. Log and — for
            // `org.matrix.msc3401.call.member` — also poke the view model
            // to retry E2EE key distribution, since the SDK's
            // `RoomInfo.activeRoomCallParticipants` accessor lags behind
            // LiveKit's `participantDidConnect` signal: a peer can join
            // the SFU before their membership state event arrives, which
            // leaves our `redistributeKey(to:)` path unable to find them.
            if let type = data["type"] as? String {
                let logAction = action
                let logType = type
                let isMemberEvent = (type == CallEncryptionService.callMemberEventType)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activityLog?.log(
                        category: .call, severity: .debug, source: "CallWidgetBridge",
                        summary: "Widget incoming \(logAction) (\(logType))",
                        roomId: self.roomId
                    )
                    if isMemberEvent {
                        self.onCallMemberStateChanged?()
                    }
                }
            }
            responseBody = [:]

        case "content_loaded":
            responseBody = [:]

        default:
            let logAction = action
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activityLog?.log(
                    category: .call, severity: .debug, source: "CallWidgetBridge",
                    summary: "Widget unhandled action: \(logAction)",
                    detail: "Acking with empty response.",
                    roomId: self.roomId
                )
            }
            responseBody = [:]
        }

        // Belt-and-braces: once the driver is sending any post-negotiation
        // event to us (send_event / send_to_device), it has approved our
        // capabilities even if we missed the explicit notify_capabilities
        // message. Flip readiness so outbound sends aren't stuck.
        if action == "send_to_device" || action == "send_event" || action == "update_state" {
            resolveReady()
        }

        await reply(to: fullMessage, requestId: requestId, response: responseBody, handle: handle)
    }

    private func reply(
        to original: [String: Any],
        requestId: String,
        response: [String: Any],
        handle: WidgetDriverHandle
    ) async {
        var reply = original
        reply["response"] = response
        // requestId is already in the echoed message; ensure it's set.
        if !requestId.isEmpty { reply["requestId"] = requestId }

        guard let json = try? Self.encode(reply) else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activityLog?.log(
                    category: .call, severity: .error, source: "CallWidgetBridge",
                    summary: "Failed to encode widget reply",
                    roomId: self.roomId
                )
            }
            return
        }
        let ok = await handle.send(msg: json)
        if !ok {
            let originalAction = original["action"] as? String ?? "?"
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activityLog?.log(
                    category: .call, severity: .warning, source: "CallWidgetBridge",
                    summary: "Widget handle.send returned false",
                    detail: "Replying to action=\(originalAction).",
                    roomId: self.roomId
                )
            }
        }
    }

    // MARK: - Incoming key plumbing

    private func handleIncomingToDevice(data: [String: Any]) {
        guard let type = data["type"] as? String,
              type == CallEncryptionService.encryptionKeysEventType,
              let sender = data["sender"] as? String else {
            return
        }
        let content = (data["content"] as? [String: Any]) ?? [:]
        guard let keyProvider else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activityLog?.log(
                    category: .call, severity: .warning, source: "CallWidgetBridge",
                    summary: "Dropping inbound encryption key — no keyProvider",
                    detail: "Sender: \(sender). The local frame cryptor isn't wired up yet.",
                    roomId: self.roomId
                )
            }
            return
        }

        // Wire format has evolved. Newer Element Call sends:
        //   content: { keys: { index, key }, member: { id, claimed_device_id }, room_id, ... }
        // Older callers (including ourselves pre-fix) send:
        //   content: { keys: [ { index, key }, ... ], device_id, call_id, ... }
        // Support both.
        var keyEntries: [[String: Any]] = []
        if let arr = content["keys"] as? [[String: Any]] {
            keyEntries = arr
        } else if let single = content["keys"] as? [String: Any] {
            keyEntries = [single]
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activityLog?.log(
                    category: .call, severity: .warning, source: "CallWidgetBridge",
                    summary: "encryption_keys to-device missing `keys` payload",
                    detail: "Sender: \(sender).",
                    roomId: self.roomId
                )
            }
            return
        }

        let member = content["member"] as? [String: Any]
        let memberId = (member?["id"] as? String) ?? ""
        let claimedDeviceId = (member?["claimed_device_id"] as? String) ?? ""
        let topDeviceId = (content["device_id"] as? String) ?? ""
        let deviceId = !claimedDeviceId.isEmpty ? claimedDeviceId : topDeviceId

        // Register the inbound key under every plausible LiveKit
        // participant identity for this peer. Which shape LiveKit assigned
        // depends on which credential path (legacy or v2) the peer took
        // when they joined the SFU — we don't necessarily know that from
        // the to-device payload alone, so register under every candidate
        // and let the cryptor pick the one whose participantId matches the
        // SFU-assigned identity.
        //
        // - Legacy (`/sfu/get`): identity = `<sender>:<deviceId>`.
        // - v2 (`/get_token`): identity = unpadded-base64 SHA-256 of
        //   `[sender, claimed_device_id, member.id]` per
        //   `lk-jwt-service/helper.go::LiveKitIdentityFor`.
        var participantIdentities: [String] = []
        if !deviceId.isEmpty {
            participantIdentities.append("\(sender):\(deviceId)")
        }
        if !claimedDeviceId.isEmpty && !memberId.isEmpty {
            let v2Identity = CallEncryptionService.liveKitIdentity(
                matrixID: sender,
                claimedDeviceID: claimedDeviceId,
                memberID: memberId
            )
            if !v2Identity.isEmpty {
                participantIdentities.append(v2Identity)
            }
        }
        if participantIdentities.isEmpty {
            // Last-resort fallback — older peers that omit both device_id
            // and member.id. Element Call's parser does the same.
            participantIdentities.append(memberId.isEmpty ? sender : memberId)
        }

        for entry in keyEntries {
            guard let base64Key = entry["key"] as? String,
                  let index = entry["index"] as? Int,
                  let keyData = Data(base64Encoded: base64Key) else {
                continue
            }
            var setFailures: [String] = []
            for participantIdentity in participantIdentities {
                if let reason = CallEncryptionService.setRawKey(
                    keyData,
                    on: keyProvider,
                    participantId: participantIdentity,
                    index: Int32(index)
                ) {
                    setFailures.append("\(participantIdentity): \(reason)")
                }
            }
            let identitiesJoined = participantIdentities.joined(separator: ", ")
            let fp = SHA256.hash(data: keyData).prefix(8).map { String(format: "%02x", $0) }.joined()
            // Snapshot the mutable accumulator into immutable lets before the
            // @Sendable Task captures it — Swift 6 rejects capturing a `var`
            // that was mutated in the enclosing scope.
            let hadFailures = !setFailures.isEmpty
            let failureNote = hadFailures ? " setRawKey failures: \(setFailures.joined(separator: "; "))." : ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activityLog?.log(
                    category: .call, severity: hadFailures ? .warning : .debug, source: "CallWidgetBridge",
                    summary: "Received E2EE key from \(sender)",
                    detail: "Routed to LiveKit participantIds: [\(identitiesJoined)]. Sender: \(sender), device: \(deviceId), member: \(memberId), index: \(index), sha256[0..8]: \(fp).\(failureNote)",
                    roomId: self.roomId
                )
            }
        }
    }

    // MARK: - Helpers

    private static func encode(_ value: [String: Any]) throws -> String {
        // `.sortedKeys` guarantees `action` is serialised before `data` in
        // top-level messages. The Rust SDK uses
        // `#[serde(tag = "action", content = "data")]` on its FromWidget enum;
        // when `data` appears first, serde falls back to its Content-buffering
        // path, which fails for `Raw<T>` newtype fields with
        // "invalid type: newtype struct, expected any valid JSON value".
        // Sorting keys sidesteps the bug entirely.
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Capabilities Provider

/// Implements `WidgetCapabilitiesProvider` by returning the Element Call
/// required permissions verbatim. The SDK intersects these with whatever
/// the widget requests over JSON.
private final class ElementCallCapabilitiesProvider: WidgetCapabilitiesProvider, @unchecked Sendable {
    private let ownUserId: String
    private let ownDeviceId: String

    init(ownUserId: String, ownDeviceId: String) {
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
    }

    func acquireCapabilities(capabilities: WidgetCapabilities) -> WidgetCapabilities {
        return getElementCallRequiredPermissions(
            ownUserId: ownUserId,
            ownDeviceId: ownDeviceId
        )
    }
}

// MARK: - Errors

enum CallWidgetBridgeError: LocalizedError {
    case notStarted
    case sendFailed
    case shutdown
    case widgetError(String)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "Widget bridge is not started."
        case .sendFailed:
            return "Failed to send widget message; driver may have exited."
        case .shutdown:
            return "Widget bridge was shut down before the request completed."
        case .widgetError(let message):
            return "Widget protocol error: \(message)"
        }
    }
}
