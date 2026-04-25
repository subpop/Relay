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
///   Rooms should be created with the correct power levels via
///   `powerLevelContentOverride` (see `MatrixService.callPowerLevels`); we
///   no longer try to mutate them at join time, matching Element Call.
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
        // `created_ts` makes each heartbeat a distinct event (Synapse can
        // dedupe identical state-event content). It also gives peers a
        // monotonic origin time for liveness tracking; matches the field
        // matrix-js-sdk's `MatrixRTCSession` writes.
        let createdTs = Int64(Date().timeIntervalSince1970 * 1000)

        // Match Element-X's exact format.
        let body: [String: Any] = [
            "application": "m.call",
            "call_id": "",
            "created_ts": createdTs,
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
        logger.info("[RTC]Call member event body: \(jsonString)")
        logger.info("[RTC]Call member state key: \(stateKey)")

        _ = try await sdkRoom.sendStateEventRaw(
            eventType: Self.callMemberEventType,
            stateKey: stateKey,
            content: jsonString
        )
        logger.info("[RTC]Sent call membership state event")
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
        logger.info("[RTC]Removed call membership state event")
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
                logger.info("[RTC]Existing call member [key=\(stateKey)]: \(contentStr)")
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
            logger.error("[RTC]LKRTCFrameCryptorKeyProvider class not found at runtime; HKDF swap skipped — E2EE interop with Element Call will fail (PBKDF2 vs HKDF mismatch)")
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
            logger.error("[RTC]LKRTCFrameCryptorKeyProvider does not expose keyDerivationAlgorithm: init; webrtc-xcframework may be < 144.x — falling back to PBKDF2 (Element Call interop will fail)")
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
            logger.error("[RTC]rtcKeyProvider ivar not found on BaseKeyProvider; HKDF swap skipped")
            return provider
        }
        object_setIvar(provider, ivar, hkdfRtc)
        logger.info("[RTC]Installed HKDF-backed LKRTCFrameCryptorKeyProvider (Element Call interop path)")
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
            logger.error("[RTC]Could not access rtcKeyProvider via KVC")
            return
        }

        // LKRTCFrameCryptorKeyProvider is an ObjC class with:
        //   - (void)setKey:(NSData *)key withIndex:(int)index forParticipant:(NSString *)participantId
        // NSObject.perform(_:with:with:) only supports 2 arguments, so we use
        // objc_msgSend to call the 3-argument method directly.
        typealias SetKeyFunc = @convention(c) (AnyObject, Selector, NSData, Int32, NSString) -> Void
        let selector = NSSelectorFromString("setKey:withIndex:forParticipant:")
        guard (rtcProvider as? NSObject)?.responds(to: selector) == true else {
            logger.error("[RTC]rtcKeyProvider does not respond to setKey:withIndex:forParticipant:")
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
        logger.info("[RTC]Set raw encryption key for participant \(participantId, privacy: .public) at index \(index) bytes=\(keyData.count) sha256[0..8]=\(fp, privacy: .public)")
    }

    /// Convenience: sets a raw key using base64-encoded key data.
    static func setRawKey(
        base64Key: String,
        on keyProvider: BaseKeyProvider,
        participantId: String,
        index: Int32 = 0
    ) {
        guard let keyData = Data(base64Encoded: base64Key) else {
            logger.error("[RTC]Invalid base64 key for participant \(participantId, privacy: .private)")
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
