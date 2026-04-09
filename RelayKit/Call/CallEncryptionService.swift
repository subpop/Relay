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
import OSLog

private let logger = Logger(subsystem: "RelayKit", category: "CallEncryption")

/// Manages MatrixRTC E2EE key exchange for LiveKit calls.
///
/// Implements the key distribution side of MSC4143 / Element Call's encryption
/// protocol: generates a random 16-byte AES-GCM key for the local participant,
/// distributes it to other participants via Matrix to-device messages, and sets
/// raw key material on the LiveKit `BaseKeyProvider` so that SFrame encryption
/// uses the correct bytes.
///
/// ## Key Exchange Flow
/// 1. On connect, generate a 16-byte random key.
/// 2. Set the key on the local participant's LiveKit encryptor via `BaseKeyProvider`.
/// 3. Send the key (base64-encoded) to all other devices in the room using the
///    `io.element.call.encryption_keys` to-device event type.
/// 4. When receiving keys from other participants (via `/sync`), set them on the
///    `BaseKeyProvider` for the corresponding participant identity.
struct CallEncryptionService {

    let homeserver: String
    let accessToken: String
    let userID: String
    let deviceID: String
    let roomID: String

    /// The to-device event type used by Element Call for key exchange.
    static let encryptionKeysEventType = "io.element.call.encryption_keys"

    /// The state event type for MatrixRTC call membership (MSC3401).
    /// Element-X uses this to discover active calls in a room.
    static let callMemberEventType = "org.matrix.msc3401.call.member"

    // MARK: - Call Membership Signaling

    /// Sends the MatrixRTC call membership state event so that Element-X and other
    /// MatrixRTC clients can discover our participation in the call.
    ///
    /// Uses the modern MSC4143 per-device format matching Element-X:
    /// - State key: `_@userId:server_deviceId_m.call`
    /// - `focus_active`: `{"type": "livekit", "focus_selection": "oldest_membership"}`
    /// - `foci_preferred`: array with the SFU service URL and room alias
    ///
    /// - Parameter sfuServiceURL: The SFU service URL from MatrixRTC discovery
    ///   (e.g. `https://livekit.example.com/livekit/jwt`).
    func sendCallMemberEvent(sfuServiceURL: String) async throws {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        let encodedEventType = Self.callMemberEventType
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? Self.callMemberEventType
        // MSC4143 state key: "_@userId:server_deviceId_m.call"
        let stateKey = "_\(userID)_\(deviceID)_m.call"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey

        guard let url = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state/\(encodedEventType)/\(encodedStateKey)") else {
            throw LiveKitCredentialError.invalidURL
        }

        let serviceURL = sfuServiceURL.trimmingCharacters(in: .init(charactersIn: "/"))

        // Match Element-X's exact format.
        let body: [String: Any] = [
            "application": "m.call",
            "call_id": "",
            "device_id": deviceID,
            "expires": 14400000,
            "focus_active": [
                "type": "livekit",
                "focus_selection": "oldest_membership"
            ] as [String: Any],
            "foci_preferred": [
                [
                    "type": "livekit",
                    "livekit_service_url": serviceURL,
                    "livekit_alias": roomID
                ] as [String: Any]
            ],
            "m.call.intent": "video",
            "membershipID": "\(userID):\(deviceID)",
            "scope": "m.room"
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        if let jsonStr = String(data: jsonData, encoding: .utf8) {
            logger.info("Call member event body: \(jsonStr)")
        }
        logger.info("Call member state key: \(stateKey)")

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let respStr = String(data: responseData, encoding: .utf8) {
                logger.error("sendCallMemberEvent failed with status \(statusCode): \(respStr)")
            }
            throw CallEncryptionError.callMemberEventFailed
        }

        logger.info("Sent call membership state event")
    }

    /// Removes the call membership state event (sets content to empty object)
    /// so Element-X knows we've left the call.
    func removeCallMemberEvent() async throws {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        let encodedEventType = Self.callMemberEventType
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? Self.callMemberEventType
        let stateKey = "_\(userID)_\(deviceID)_m.call"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey

        guard let url = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state/\(encodedEventType)/\(encodedStateKey)") else {
            throw LiveKitCredentialError.invalidURL
        }

        let body: [String: Any] = [:]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("removeCallMemberEvent failed with status \(statusCode)")
            return
        }

        logger.info("Removed call membership state event")
    }

    // MARK: - Debug: Fetch Existing Call Members

    /// Fetches all existing `org.matrix.msc3401.call.member` state events from
    /// the room for debugging interoperability issues.
    func fetchCallMemberEvents() async {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID

        guard let url = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        for event in events {
            guard let type = event["type"] as? String,
                  type == Self.callMemberEventType else { continue }
            let stateKey = event["state_key"] as? String ?? "(none)"
            if let content = event["content"],
               let contentData = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]),
               let contentStr = String(data: contentData, encoding: .utf8) {
                logger.info("Existing call member [key=\(stateKey)]: \(contentStr)")
            }
        }
    }

    // MARK: - Room Call Setup

    /// Ensures the room's power levels allow any member to send call-related
    /// state events. Element-web does this automatically when a call is started.
    ///
    /// Sets `org.matrix.msc3401.call.member` and `io.element.call.encryption_keys`
    /// to power level 0 in the room's `m.room.power_levels` state event.
    ///
    /// This is idempotent — if the levels are already correct, the PUT overwrites
    /// with the same content.
    func enableCallPowerLevels() async throws {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID

        // 1. Fetch current power levels.
        guard let getURL = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state/m.room.power_levels/") else {
            throw LiveKitCredentialError.invalidURL
        }

        var getRequest = URLRequest(url: getURL)
        getRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, getResponse) = try await URLSession.shared.data(for: getRequest)
        guard let http = getResponse as? HTTPURLResponse, http.statusCode == 200 else {
            logger.warning("Could not fetch power levels (status \((getResponse as? HTTPURLResponse)?.statusCode ?? -1))")
            return
        }

        guard var powerLevels = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // 2. Merge call event types into the events dict at PL 0.
        var events = (powerLevels["events"] as? [String: Any]) ?? [:]
        let callEventTypes = [
            Self.callMemberEventType,
            Self.encryptionKeysEventType
        ]

        var needsUpdate = false
        for eventType in callEventTypes {
            if events[eventType] as? Int != 0 {
                events[eventType] = 0
                needsUpdate = true
            }
        }

        guard needsUpdate else {
            logger.info("Call power levels already configured")
            return
        }

        powerLevels["events"] = events

        // 3. PUT the updated power levels.
        guard let putURL = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state/m.room.power_levels/") else {
            throw LiveKitCredentialError.invalidURL
        }

        let jsonData = try JSONSerialization.data(withJSONObject: powerLevels)

        var putRequest = URLRequest(url: putURL)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = jsonData

        let (_, putResponse) = try await URLSession.shared.data(for: putRequest)
        guard let putHTTP = putResponse as? HTTPURLResponse, (200...299).contains(putHTTP.statusCode) else {
            let statusCode = (putResponse as? HTTPURLResponse)?.statusCode ?? -1
            logger.warning("Failed to update call power levels (status \(statusCode))")
            return
        }

        logger.info("Enabled call power levels for room")
    }

    // MARK: - Key Generation

    /// Generates a cryptographically random 16-byte key suitable for AES-128-GCM.
    static func generateKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Failed to generate random key bytes")
        return Data(bytes)
    }

    // MARK: - Key Provider Setup

    /// Sets a raw key on a `BaseKeyProvider` for the given participant, bypassing
    /// the String-based `setKey(key:participantId:index:)` method which would
    /// UTF-8-encode the string (wrong for raw AES key bytes).
    ///
    /// `BaseKeyProvider` is decorated with `@objcMembers`, so its internal
    /// `rtcKeyProvider` (an `LKRTCFrameCryptorKeyProvider`) is accessible via KVC.
    /// The ObjC provider accepts `NSData` directly.
    static func setRawKey(
        _ keyData: Data,
        on keyProvider: BaseKeyProvider,
        participantId: String,
        index: Int32 = 0
    ) {
        guard let rtcProvider = keyProvider.value(forKey: "rtcKeyProvider") as AnyObject? else {
            logger.error("Could not access rtcKeyProvider via KVC")
            return
        }

        // LKRTCFrameCryptorKeyProvider is an ObjC class with:
        //   - (void)setKey:(NSData *)key withIndex:(int)index forParticipant:(NSString *)participantId
        // NSObject.perform(_:with:with:) only supports 2 arguments, so we use
        // objc_msgSend to call the 3-argument method directly.
        typealias SetKeyFunc = @convention(c) (AnyObject, Selector, NSData, Int32, NSString) -> Void
        let selector = NSSelectorFromString("setKey:withIndex:forParticipant:")
        guard (rtcProvider as? NSObject)?.responds(to: selector) == true else {
            logger.error("rtcKeyProvider does not respond to setKey:withIndex:forParticipant:")
            return
        }

        let imp = unsafeBitCast(
            (rtcProvider as AnyObject).method(for: selector),
            to: SetKeyFunc.self
        )
        imp(rtcProvider, selector, keyData as NSData, index, participantId as NSString)
        logger.info("Set raw encryption key for participant \(participantId, privacy: .private) at index \(index)")
    }

    /// Convenience: sets a raw key using base64-encoded key data.
    static func setRawKey(
        base64Key: String,
        on keyProvider: BaseKeyProvider,
        participantId: String,
        index: Int32 = 0
    ) {
        guard let keyData = Data(base64Encoded: base64Key) else {
            logger.error("Invalid base64 key for participant \(participantId, privacy: .private)")
            return
        }
        setRawKey(keyData, on: keyProvider, participantId: participantId, index: index)
    }

    // MARK: - Key Distribution (to-device messages)

    /// Sends the local participant's encryption key to all devices of the given
    /// users via a Matrix to-device message.
    ///
    /// Uses the REST API directly because the Matrix Rust SDK (v26.x) does not
    /// expose `sendToDevice` in the Swift FFI.
    ///
    /// - Parameters:
    ///   - key: The raw 16-byte encryption key.
    ///   - keyIndex: The key index (0-255, cycles on ratchet).
    ///   - targetUsers: A mapping of user ID to an array of device IDs.
    func sendKey(
        _ key: Data,
        keyIndex: Int,
        to targetUsers: [String: [String]]
    ) async throws {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let txnId = UUID().uuidString
        let encodedEventType = Self.encryptionKeysEventType
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? Self.encryptionKeysEventType

        guard let url = URL(string: "\(base)/_matrix/client/v3/sendToDevice/\(encodedEventType)/\(txnId)") else {
            throw LiveKitCredentialError.invalidURL
        }

        let base64Key = key.base64EncodedString()
        let sentTs = Int(Date().timeIntervalSince1970 * 1000)

        // Build the per-user/per-device message content.
        var messages: [String: [String: Any]] = [:]
        for (userId, deviceIds) in targetUsers {
            var deviceMessages: [String: Any] = [:]
            for deviceId in deviceIds {
                deviceMessages[deviceId] = [
                    "keys": [
                        ["index": keyIndex, "key": base64Key]
                    ],
                    "room_id": roomID,
                    "member": [
                        "claimed_device_id": self.deviceID,
                        "id": "\(self.userID):\(self.deviceID)"
                    ],
                    "session": [
                        "call_id": "",
                        "application": "m.call",
                        "scope": "m.room"
                    ],
                    "sent_ts": sentTs
                ] as [String: Any]
            }
            messages[userId] = deviceMessages
        }

        let body: [String: Any] = ["messages": messages]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("sendToDevice failed with status \(statusCode)")
            throw CallEncryptionError.keyDistributionFailed
        }

        logger.info("Sent encryption key (index \(keyIndex)) to \(targetUsers.count) user(s)")
    }

    // MARK: - Key Distribution (room state events)

    /// Sends the local participant's encryption key as a room state event.
    ///
    /// This provides a second transport for key exchange that other Relay clients
    /// can observe via the room timeline, working around the Matrix Rust SDK's
    /// inability to deliver to-device events to the app layer.
    ///
    /// The state key is `"{userID}:{deviceID}"` so each participant's key is
    /// a distinct state entry that overwrites on update.
    func sendKeyAsStateEvent(
        _ key: Data,
        keyIndex: Int
    ) async throws {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        let stateKey = "\(userID):\(deviceID)"
        let encodedStateKey = stateKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stateKey
        let encodedEventType = Self.encryptionKeysEventType
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? Self.encryptionKeysEventType

        guard let url = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state/\(encodedEventType)/\(encodedStateKey)") else {
            throw LiveKitCredentialError.invalidURL
        }

        let base64Key = key.base64EncodedString()
        let body: [String: Any] = [
            "keys": [
                ["index": keyIndex, "key": base64Key]
            ],
            "member": [
                "claimed_device_id": deviceID,
                "id": "\(userID):\(deviceID)"
            ],
            "session": [
                "call_id": "",
                "application": "m.call",
                "scope": "m.room"
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("sendStateEvent failed with status \(statusCode)")
            throw CallEncryptionError.keyDistributionFailed
        }

        logger.info("Sent encryption key as state event (index \(keyIndex))")
    }

    // MARK: - Key Reception (timeline listener)

    /// Starts listening for encryption key state events on the room timeline.
    ///
    /// When another participant sends their key as a room state event of type
    /// `io.element.call.encryption_keys`, this listener parses the key and sets
    /// it on the given `BaseKeyProvider` so LiveKit can decrypt that participant's
    /// media frames.
    ///
    /// - Parameters:
    ///   - timeline: The Matrix SDK `Timeline` for the call's room.
    ///   - keyProvider: The LiveKit key provider to set received keys on.
    ///   - localIdentity: The local participant's identity (to skip our own events).
    /// - Returns: A `TaskHandle` that must be retained to keep the listener alive.
    @MainActor
    static func startListeningForKeys(
        timeline: Timeline,
        keyProvider: BaseKeyProvider,
        localIdentity: String
    ) async -> TaskHandle {
        // Capture the event type as a local to avoid referencing the MainActor-isolated
        // static property from the nonisolated SDKListener callback.
        let eventType = Self.encryptionKeysEventType
        let localPrefix = localIdentity.components(separatedBy: ":").prefix(2).joined(separator: ":")

        let listener = SDKListener<[TimelineDiff]> { diffs in
            // SDKListener callbacks arrive on an unspecified thread.
            // Dispatch to the main actor for safe access to logger and setRawKey.
            Task { @MainActor in
                let items = extractTimelineItems(from: diffs)
                for item in items {
                    guard let eventItem = item.asEvent() else { continue }

                    guard case .state(let stateKey, let otherState) = eventItem.content,
                          case .custom(let type) = otherState,
                          type == eventType else {
                        continue
                    }

                    // Skip our own events.
                    if stateKey.hasPrefix(localPrefix) { continue }

                    let sender = eventItem.sender

                    let debugInfo = eventItem.lazyProvider.debugInfo()
                    guard let jsonString = debugInfo.originalJson,
                          let jsonData = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        logger.warning("Could not parse encryption key event JSON from \(sender, privacy: .private)")
                        continue
                    }

                    // The raw JSON is the full event envelope; keys are in "content".
                    let content = (json["content"] as? [String: Any]) ?? json

                    guard let keysArray = content["keys"] as? [[String: Any]] else {
                        logger.warning("No keys array in encryption key event from \(sender, privacy: .private)")
                        continue
                    }

                    let participantIdentity = stateKey

                    for keyEntry in keysArray {
                        guard let base64Key = keyEntry["key"] as? String,
                              let index = keyEntry["index"] as? Int else {
                            continue
                        }
                        Self.setRawKey(
                            base64Key: base64Key,
                            on: keyProvider,
                            participantId: participantIdentity,
                            index: Int32(index)
                        )
                        logger.info("Received encryption key from \(sender, privacy: .private) (index \(index))")
                    }
                }
            }
        }

        return await timeline.addListener(listener: listener)
    }

    // MARK: - Room Member Discovery

    /// Fetches the list of joined members in the room so we know who to send
    /// encryption keys to. Uses the Matrix REST API directly.
    func fetchJoinedMembers() async throws -> [String: [String]] {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        guard let url = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/joined_members") else {
            throw LiveKitCredentialError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CallEncryptionError.memberDiscoveryFailed
        }

        // Response: { "joined": { "@user:server": { ... }, ... } }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let joined = json["joined"] as? [String: Any] else {
            throw CallEncryptionError.memberDiscoveryFailed
        }

        // For now, return each user mapped to "*" (wildcard) since we don't have
        // per-device granularity from joined_members. The homeserver will fan out.
        var result: [String: [String]] = [:]
        for userId in joined.keys where userId != self.userID {
            result[userId] = ["*"]
        }
        return result
    }
}

// MARK: - Helpers

/// Extracts all `TimelineItem` values from a batch of timeline diffs.
private func extractTimelineItems(from diffs: [TimelineDiff]) -> [TimelineItem] {
    var items: [TimelineItem] = []
    for diff in diffs {
        switch diff {
        case .append(let values):
            items.append(contentsOf: values)
        case .pushFront(let value):
            items.append(value)
        case .pushBack(let value):
            items.append(value)
        case .insert(_, let value):
            items.append(value)
        case .set(_, let value):
            items.append(value)
        case .reset(let values):
            items.append(contentsOf: values)
        case .clear, .popFront, .popBack, .remove, .truncate:
            break
        }
    }
    return items
}

// MARK: - Errors

enum CallEncryptionError: LocalizedError {
    case keyDistributionFailed
    case memberDiscoveryFailed
    case callMemberEventFailed

    var errorDescription: String? {
        switch self {
        case .keyDistributionFailed:
            return "Failed to distribute encryption keys to call participants."
        case .memberDiscoveryFailed:
            return "Failed to discover room members for key exchange."
        case .callMemberEventFailed:
            return "Failed to send call membership state event."
        }
    }
}
