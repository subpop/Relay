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
import os
import OSLog

private let logger = Logger(subsystem: "RelayKit", category: "CallWidgetBridge")

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
            logger.info("[RTC]WidgetDriver.run returned; driver exited")
            self?.resolveReady()
        }

        recvTask = Task { [weak self] in
            await self?.recvLoop(handle: handle)
        }

        // Kick the state machine off the "Unset" state. Fire-and-forget —
        // the response just echoes back through recvLoop.
        Task { [weak self] in
            do {
                try await self?.sendRequest(action: "content_loaded", data: [:])
                logger.info("[RTC]Widget content_loaded acknowledged by driver")
            } catch {
                logger.warning("[RTC]content_loaded failed: \(error.localizedDescription, privacy: .private)")
            }
        }

        logger.info("[RTC]CallWidgetBridge started (widgetId=\(self.widgetId, privacy: .public))")
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
        logger.info("[RTC]CallWidgetBridge shut down")
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
        logger.info("[RTC]Sent encryption key (index \(keyIndex)) to \(toMembers.count) user(s) member.id=\(self.membershipId, privacy: .public) sha256[0..8]=\(fp, privacy: .public)")
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
        logger.info("[RTC]Sent call member state event (state_key=\(stateKey, privacy: .public))")
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
                logger.info("[RTC]WidgetDriverHandle.recv returned nil; loop exiting")
                break
            }

            // SECURITY: never log the raw widget JSON. Outbound and inbound
            // `send_to_device` payloads of type `io.element.call.encryption_keys`
            // carry raw AES keys in the `keys.key` field — those would land
            // unredacted in the system log. Action / type only; full bodies
            // are .private so they're stripped from non-debug Console output.
            logger.debug("[RTC]widget recv (\(raw.count) bytes)")

            guard let data = raw.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("[RTC]Non-JSON message from widget driver: \(raw, privacy: .private)")
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
                logger.warning("[RTC]Widget message missing action: \(raw, privacy: .private)")
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
            // directly; we just need to ack these. Log and move on.
            if let type = data["type"] as? String {
                logger.info("[RTC]widget incoming \(action, privacy: .public) type=\(type, privacy: .public)")
            }
            responseBody = [:]

        case "content_loaded":
            responseBody = [:]

        default:
            logger.info("[RTC]widget unhandled action=\(action, privacy: .public); acking with {}")
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
            logger.error("[RTC]Failed to encode widget reply")
            return
        }
        let ok = await handle.send(msg: json)
        if !ok {
            logger.warning("[RTC]handle.send returned false replying to action=\(original["action"] as? String ?? "?", privacy: .public)")
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
            logger.warning("[RTC]No keyProvider; dropping inbound key from \(sender, privacy: .private)")
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
            logger.warning("[RTC]encryption_keys to-device missing keys from \(sender, privacy: .private)")
            return
        }

        let member = content["member"] as? [String: Any]
        let memberId = (member?["id"] as? String) ?? ""
        let claimedDeviceId = (member?["claimed_device_id"] as? String) ?? ""
        let topDeviceId = (content["device_id"] as? String) ?? ""
        let deviceId = !claimedDeviceId.isEmpty ? claimedDeviceId : topDeviceId

        // LiveKit participant identity lookup order. Element Call connects to
        // the SFU with identity `@user:server:deviceId` (confirmed in the
        // MatrixRTC JWT grant), so that's what we need to key on for the
        // LKRTCFrameCryptorKeyProvider to route the key to the right
        // participant's decoder.
        //
        // `member.id` is the MSC4143 per-membership UUID — an *event*-level
        // identifier, not a LiveKit participant identity. It only enters the
        // fallback chain so older peers that somehow omit the device id still
        // get routed.
        let participantIdentity: String
        if !deviceId.isEmpty {
            participantIdentity = "\(sender):\(deviceId)"
        } else if !memberId.isEmpty {
            participantIdentity = memberId
        } else {
            participantIdentity = sender
        }

        for entry in keyEntries {
            guard let base64Key = entry["key"] as? String,
                  let index = entry["index"] as? Int,
                  let keyData = Data(base64Encoded: base64Key) else {
                continue
            }
            CallEncryptionService.setRawKey(
                keyData,
                on: keyProvider,
                participantId: participantIdentity,
                index: Int32(index)
            )
            // Log with `.public` so we can correlate the key routing
            // identity (what we register the frame-decryption key under)
            // with the actual LiveKit participant identity (logged on
            // connect) — if these do not match byte-for-byte, LiveKit will
            // silently fail to decrypt this peer's frames.
            logger.info("[RTC]Applied inbound key -> routed to LiveKit participantId=\(participantIdentity, privacy: .public) sender=\(sender, privacy: .public) device=\(deviceId, privacy: .public) member=\(memberId, privacy: .public) index=\(index)")
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
