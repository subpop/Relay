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

import CryptoKit
import Foundation
import LiveKit
import MatrixRustSDK
import OSLog

private let logger = Logger(subsystem: "RelayKit", category: "CallEncryption")

/// Helpers for MatrixRTC call-member state signaling, power-level bootstrap,
/// and LiveKit key provider plumbing.
///
/// Key distribution for `io.element.call.encryption_keys` is handled by
/// ``CallWidgetBridge``, which speaks the Widget API directly to the
/// Matrix Rust SDK's `WidgetDriver`. The SDK handles Olm encryption of the
/// to-device payloads transparently, which the previous raw-REST path could
/// not do — Element-X rejected the plaintext keys and the call failed to
/// negotiate.
///
/// What remains in this type:
/// - ``sendCallMemberEvent(sfuServiceURL:)`` / ``removeCallMemberEvent()`` —
///   MatrixRTC member state via `sendStateEventRaw` on the SDK room.
/// - ``enableCallPowerLevels()`` — ensures call state events are sendable
///   at PL 0 so ordinary members can join.
/// - ``generateKey()`` / ``setRawKey(_:on:participantId:index:)`` —
///   LiveKit `BaseKeyProvider` plumbing that bypasses the String-based
///   `setKey(...)` API so raw AES bytes are installed unmangled.
struct CallEncryptionService {

    let homeserver: String
    let accessToken: String
    let userID: String
    let deviceID: String
    let roomID: String
    /// The Matrix SDK room, used for `sendStateEventRaw` which goes through
    /// the SDK's authenticated client instead of raw REST API calls.
    let sdkRoom: MatrixRustSDK.Room?

    /// The to-device event type used by Element Call for key exchange.
    static let encryptionKeysEventType = "io.element.call.encryption_keys"

    /// The state event type for MatrixRTC call membership (MSC3401).
    /// Element-X uses this to discover active calls in a room.
    static let callMemberEventType = "org.matrix.msc3401.call.member"

    // MARK: - Call Membership Signaling

    /// Sends the MatrixRTC call membership state event so that Element-X and
    /// other MatrixRTC clients can discover our participation in the call.
    ///
    /// Uses the modern MSC4143 per-device format matching Element-X:
    /// - State key: `_@userId:server_deviceId_m.call`
    /// - `focus_active`: `{"type": "livekit", "focus_selection": "oldest_membership"}`
    /// - `foci_preferred`: array with the SFU service URL and room alias
    ///
    /// - Parameters:
    ///   - sfuServiceURL: The SFU service URL from MatrixRTC discovery
    ///     (e.g. `https://livekit.example.com/livekit/jwt`).
    ///   - membershipId: The per-call membership UUID. Must match the
    ///     `member.id` field in outbound encryption_keys to-device payloads
    ///     so peers can correlate our key with our membership event. When
    ///     `nil`, falls back to `userID:deviceID`.
    func sendCallMemberEvent(sfuServiceURL: String, membershipId: String? = nil) async throws {
        guard let sdkRoom else {
            throw CallEncryptionError.callMemberEventFailed
        }

        let stateKey = "_\(userID)_\(deviceID)_m.call"
        let serviceURL = sfuServiceURL.trimmingCharacters(in: .init(charactersIn: "/"))
        let membership = membershipId ?? "\(userID):\(deviceID)"

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
            "membershipID": membership,
            "scope": "m.room"
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        logger.info("Call member event body: \(jsonString)")
        logger.info("Call member state key: \(stateKey)")

        _ = try await sdkRoom.sendStateEventRaw(
            eventType: Self.callMemberEventType,
            stateKey: stateKey,
            content: jsonString
        )
        logger.info("Sent call membership state event")
    }

    /// Removes the call membership state event (sets content to empty object)
    /// so Element-X knows we've left the call.
    func removeCallMemberEvent() async throws {
        guard let sdkRoom else {
            throw CallEncryptionError.callMemberEventFailed
        }
        let stateKey = "_\(userID)_\(deviceID)_m.call"
        _ = try await sdkRoom.sendStateEventRaw(
            eventType: Self.callMemberEventType,
            stateKey: stateKey,
            content: "{}"
        )
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

    /// Returns a `userId -> [deviceId]` map of *other* users currently in the
    /// call, parsed from `org.matrix.msc3401.call.member` state events.
    ///
    /// Element-X writes per-device call-member events with state key
    /// `_<userId>_<deviceId>_m.call`. We walk the full room state, filter for
    /// non-empty call-member content (empty content means the participant
    /// has left), and extract `(userId, deviceId)` from the state key.
    /// Our own `userID` is excluded.
    func fetchCallTargets() async -> [String: [String]] {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID

        guard let url = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state") else { return [:] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var targets: [String: Set<String>] = [:]
        for event in events {
            guard let type = event["type"] as? String,
                  type == Self.callMemberEventType,
                  let stateKey = event["state_key"] as? String,
                  let content = event["content"] as? [String: Any],
                  !content.isEmpty else { continue }

            // State key format: `_<userId>_<deviceId>_m.call` where userId is
            // itself `@localpart:server.tld`. Strip the leading underscore
            // and the trailing `_m.call` marker, then split on the *last*
            // underscore to separate deviceId from userId.
            guard stateKey.hasPrefix("_"), stateKey.hasSuffix("_m.call") else { continue }
            let trimmed = String(stateKey.dropFirst().dropLast("_m.call".count))
            guard let lastUnderscore = trimmed.lastIndex(of: "_") else { continue }
            let userId = String(trimmed[..<lastUnderscore])
            let deviceId = String(trimmed[trimmed.index(after: lastUnderscore)...])
            guard userId != self.userID else { continue }

            targets[userId, default: []].insert(deviceId)
        }

        return targets.mapValues { Array($0) }
    }

    // MARK: - Room Call Setup

    /// Ensures the room's power levels allow any member to send call-related
    /// state events (`org.matrix.msc3401.call.member` and
    /// `io.element.call.encryption_keys` at power level 0).
    ///
    /// Only succeeds if the current user has permission to update power levels
    /// (typically room admins/mods). Fails silently for non-admin users — rooms
    /// should be created with the correct power levels via `powerLevelContentOverride`.
    func enableCallPowerLevels() async throws {
        guard let sdkRoom else {
            logger.warning("No SDK room — cannot check/update power levels")
            return
        }

        // Check if we can already send call member events.
        let powerLevels = try await sdkRoom.getPowerLevels()
        let canSendCallMember = powerLevels.canOwnUserSendState(stateEvent: .callMember)
        let canSendEncKeys = powerLevels.canOwnUserSendState(
            stateEvent: .custom(value: Self.encryptionKeysEventType)
        )

        if canSendCallMember && canSendEncKeys {
            logger.info("Call power levels already allow sending")
            return
        }

        logger.info("Call power levels need update (callMember=\(canSendCallMember), encKeys=\(canSendEncKeys))")

        // Fetch current power levels JSON, merge in call event types at PL 0,
        // and re-send via the SDK. This only works if we're admin/mod.
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID

        guard let getURL = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state/m.room.power_levels/") else {
            return
        }

        var getRequest = URLRequest(url: getURL)
        getRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, getResponse) = try await URLSession.shared.data(for: getRequest)
        guard let http = getResponse as? HTTPURLResponse, http.statusCode == 200,
              var plDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Could not fetch power levels for update")
            return
        }

        var events = (plDict["events"] as? [String: Any]) ?? [:]
        events[Self.callMemberEventType] = 0
        events[Self.encryptionKeysEventType] = 0
        plDict["events"] = events

        let jsonData = try JSONSerialization.data(withJSONObject: plDict)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        do {
            _ = try await sdkRoom.sendStateEventRaw(
                eventType: "m.room.power_levels",
                stateKey: "",
                content: jsonString
            )
            logger.info("Enabled call power levels for room")
        } catch {
            logger.warning("Cannot update call power levels (likely not admin): \(error.localizedDescription)")
        }
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

    /// Builds a `BaseKeyProvider` whose internal `LKRTCFrameCryptorKeyProvider`
    /// is configured for **HKDF-SHA256** key derivation instead of the LiveKit
    /// Swift SDK's default of **PBKDF2**.
    ///
    /// Why this exists: `BaseKeyProvider`'s public inits forward to the 6-arg
    /// ObjC initializer which hard-codes PBKDF2 (libwebrtc's default). Element
    /// Call / livekit-client JS imports raw key material as HKDF and derives
    /// the AES-GCM key with HKDF-SHA256, salt `"LKFrameEncryptionKey"`,
    /// info = 128 zero bytes. Starting from byte-identical IKM, PBKDF2 on
    /// our side and HKDF on the peer produce **different AES keys**, so every
    /// frame's GCM auth tag fails on the peer. The symptom is the same as
    /// the "maximum ratchet attempts exceeded / key marked as invalid" loop
    /// we were chasing — symmetric, codec-independent, survives timing and
    /// identity fixes.
    ///
    /// The 7-arg ObjC init that accepts `keyDerivationAlgorithm:` is exposed
    /// in `webrtc-xcframework` 144.7559.x and newer. We look it up via the
    /// Objective-C runtime so we don't need a direct module dependency on
    /// `LiveKitWebRTC` from RelayKit. If the runtime lookup fails (older
    /// framework), we fall back to the default PBKDF2 provider so the call
    /// still builds — but interop with Element Call will stay broken.
    static func makeHKDFKeyProvider(
        ratchetWindowSize: Int32 = 10,
        keyRingSize: Int32 = 256
    ) -> BaseKeyProvider {
        let options = KeyProviderOptions(
            sharedKey: false,
            ratchetWindowSize: ratchetWindowSize,
            keyRingSize: keyRingSize
        )
        let provider = BaseKeyProvider(options: options)

        guard let cls = NSClassFromString("LKRTCFrameCryptorKeyProvider") as? NSObject.Type else {
            logger.error("LKRTCFrameCryptorKeyProvider class not found at runtime; HKDF swap skipped — E2EE interop with Element Call will fail (PBKDF2 vs HKDF mismatch)")
            return provider
        }

        let initSel = NSSelectorFromString(
            "initWithRatchetSalt:ratchetWindowSize:sharedKeyMode:uncryptedMagicBytes:failureTolerance:keyRingSize:discardFrameWhenCryptorNotReady:keyDerivationAlgorithm:"
        )
        // Swift blocks `NSObject.alloc()`, so go through the ObjC runtime.
        let allocSel = NSSelectorFromString("alloc")
        typealias AllocFunc = @convention(c) (AnyClass, Selector) -> AnyObject
        let allocImp = unsafeBitCast(
            (cls as AnyClass).method(for: allocSel),
            to: AllocFunc.self
        )
        let allocated = allocImp(cls, allocSel)
        guard (allocated as AnyObject).responds(to: initSel) else {
            logger.error("LKRTCFrameCryptorKeyProvider does not expose keyDerivationAlgorithm: init; webrtc-xcframework may be < 144.x — falling back to PBKDF2 (Element Call interop will fail)")
            return provider
        }

        typealias InitFunc = @convention(c) (
            AnyObject, Selector, NSData, Int32, ObjCBool, NSData?, Int32, Int32, ObjCBool, UInt
        ) -> AnyObject
        let imp = unsafeBitCast(
            (allocated as AnyObject).method(for: initSel),
            to: InitFunc.self
        )
        // RTCKeyDerivationAlgorithmHKDF is the second enum case (== 1).
        let hkdfKeyDerivation: UInt = 1
        let hkdfRtc = imp(
            allocated,
            initSel,
            options.ratchetSalt as NSData,
            options.ratchetWindowSize,
            ObjCBool(options.sharedKey),
            options.uncryptedMagicBytes as NSData,
            options.failureTolerance,
            options.keyRingSize,
            ObjCBool(false),
            hkdfKeyDerivation
        )

        guard let ivar = class_getInstanceVariable(BaseKeyProvider.self, "rtcKeyProvider") else {
            logger.error("rtcKeyProvider ivar not found on BaseKeyProvider; HKDF swap skipped")
            return provider
        }
        object_setIvar(provider, ivar, hkdfRtc)
        logger.info("Installed HKDF-backed LKRTCFrameCryptorKeyProvider (Element Call interop path)")
        return provider
    }

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
        // SHA-256 fingerprint of the raw IKM so we can confirm the exact same
        // 16 bytes end up on the wire. Matches the fingerprint logged in
        // CallWidgetBridge.sendEncryptionKey. Diverging fingerprints mean
        // our local frame cryptor and the peer are using different keys —
        // the #1 root cause of "maximum ratchet attempts exceeded" on an
        // otherwise-correct key-exchange handshake.
        let fp = SHA256.hash(data: keyData).prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.info("Set raw encryption key for participant \(participantId, privacy: .public) at index \(index) bytes=\(keyData.count) sha256[0..8]=\(fp, privacy: .public)")
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
}

// MARK: - Errors

enum CallEncryptionError: LocalizedError {
    case callMemberEventFailed

    var errorDescription: String? {
        switch self {
        case .callMemberEventFailed:
            return "Failed to send call membership state event."
        }
    }
}
