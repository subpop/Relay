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
import ObjectiveC.runtime

/// LiveKit E2EE plumbing for MatrixRTC calls.
///
/// Key generation and participant-identity derivation live in MatrixKit's
/// ``CallKeyDistributor`` (``generateKey()`` / ``liveKitIdentity``); this
/// file holds the two pieces that must touch LiveKit types directly:
///
/// - ``makeHKDFKeyProvider(ratchetWindowSize:keyRingSize:)`` builds a
///   `BaseKeyProvider` whose internal frame cryptor derives keys with
///   HKDF-SHA256 instead of the SDK default PBKDF2, matching Element Call.
/// - ``setRawKey(_:on:participantId:index:)`` installs raw AES key bytes
///   under a participant identity, bypassing the string-based setter.
enum CallE2EE {
    /// Builds a `BaseKeyProvider` whose internal `LKRTCFrameCryptorKeyProvider`
    /// is configured for **HKDF-SHA256** key derivation instead of the LiveKit
    /// Swift SDK's default of **PBKDF2**.
    ///
    /// Element Call / livekit-client JS imports raw key material as HKDF and
    /// derives the AES-GCM key with HKDF-SHA256, salt `"LKFrameEncryptionKey"`,
    /// info = 128 zero bytes. Starting from byte-identical IKM, PBKDF2 on our
    /// side and HKDF on the peer produce **different AES keys**, so every
    /// frame's GCM auth tag fails on the peer.
    ///
    /// The 7-arg ObjC init that accepts `keyDerivationAlgorithm:` is exposed
    /// in `webrtc-xcframework` 144.7559.x and newer. We look it up via the
    /// Objective-C runtime so we don't need a direct module dependency on
    /// `LiveKitWebRTC`. If the runtime lookup fails, we fall back to the
    /// default PBKDF2 provider — but interop with Element Call will stay broken.
    static func makeHKDFKeyProvider(
        ratchetWindowSize: Int32 = 10,
        keyRingSize: Int32 = 256
    ) -> (provider: BaseKeyProvider, hkdfInstalled: Bool, fallbackReason: String?) {
        let options = KeyProviderOptions(
            sharedKey: false,
            ratchetWindowSize: ratchetWindowSize,
            keyRingSize: keyRingSize
        )
        let provider = BaseKeyProvider(options: options)

        guard let cls = NSClassFromString("LKRTCFrameCryptorKeyProvider") as? NSObject.Type else {
            return (provider, false, "LKRTCFrameCryptorKeyProvider class not found at runtime")
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
            return (provider, false, "LKRTCFrameCryptorKeyProvider does not expose keyDerivationAlgorithm: init (webrtc-xcframework may be < 144.x)")
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
            return (provider, false, "rtcKeyProvider ivar not found on BaseKeyProvider")
        }
        object_setIvar(provider, ivar, hkdfRtc)
        return (provider, true, nil)
    }

    /// Sets a raw key on a `BaseKeyProvider` for the given participant, bypassing
    /// the String-based `setKey(key:participantId:index:)` method which would
    /// UTF-8-encode the string (wrong for raw AES key bytes).
    ///
    /// Returns `nil` on success, or a short failure reason string the caller can
    /// surface in the Activity Log.
    @discardableResult
    static func setRawKey(
        _ keyData: Data,
        on keyProvider: BaseKeyProvider,
        participantId: String,
        index: Int32 = 0
    ) -> String? {
        guard let rtcProvider = keyProvider.value(forKey: "rtcKeyProvider") as AnyObject? else {
            return "Could not access rtcKeyProvider via KVC"
        }

        // LKRTCFrameCryptorKeyProvider is an ObjC class with:
        //   - (void)setKey:(NSData *)key withIndex:(int)index forParticipant:(NSString *)participantId
        // NSObject.perform(_:with:with:) only supports 2 arguments, so we use
        // objc_msgSend to call the 3-argument method directly.
        typealias SetKeyFunc = @convention(c) (AnyObject, Selector, NSData, Int32, NSString) -> Void
        let selector = NSSelectorFromString("setKey:withIndex:forParticipant:")
        guard (rtcProvider as? NSObject)?.responds(to: selector) == true else {
            return "rtcKeyProvider does not respond to setKey:withIndex:forParticipant:"
        }

        let imp = unsafeBitCast(
            (rtcProvider as AnyObject).method(for: selector),
            to: SetKeyFunc.self
        )
        imp(rtcProvider, selector, keyData as NSData, index, participantId as NSString)
        return nil
    }

    /// Convenience: sets a raw key using base64-encoded key data.
    /// Returns `nil` on success or a short failure reason.
    @discardableResult
    static func setRawKey(
        base64Key: String,
        on keyProvider: BaseKeyProvider,
        participantId: String,
        index: Int32 = 0
    ) -> String? {
        guard let keyData = Data(base64Encoded: base64Key) else {
            return "Invalid base64 key for participant \(participantId)"
        }
        return setRawKey(keyData, on: keyProvider, participantId: participantId, index: index)
    }
}
