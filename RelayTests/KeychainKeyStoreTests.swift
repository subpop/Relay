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
import MatrixKitCrypto
import RelayShared
import Security
import Testing

@testable import Relay

@Suite(.serialized)
struct KeychainKeyStoreTests {
    private let store = KeychainKeyStore()

    private func makeKey() -> KeyStoreKey {
        KeyStoreKey(service: "test", account: UUID().uuidString)
    }

    @Test func roundTripsAndDeletes() async throws {
        let key = makeKey()
        try await store.save(Data("one".utf8), for: key)
        try await store.save(Data("two".utf8), for: key)
        #expect(try await store.load(key) == Data("two".utf8))
        try await store.delete(key)
        #expect(try await store.load(key) == nil)
    }

    @Test func storesItemsThisDeviceOnly() async throws {
        let key = makeKey()
        try await store.save(Data("secret".utf8), for: key)
        defer { Task { try? await store.delete(key) } }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.subpop.Relay.crypto.debug.\(key.service)",
            kSecAttrAccount as String: key.account,
            kSecAttrAccessGroup as String: AppGroup.identifier,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = result as? [String: Any]
        #expect(
            attributes?[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func migratesLegacyItem() async throws {
        let key = makeKey()
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.subpop.Relay.crypto.debug.\(key.service)",
            kSecAttrAccount as String: key.account,
            kSecAttrAccessGroup as String: AppGroup.identifier,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: Data("legacy".utf8),
        ]
        #expect(SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess)

        #expect(try await store.load(key) == Data("legacy".utf8))
        #expect(try await store.load(key) == Data("legacy".utf8))
        try await store.delete(key)
        #expect(try await store.load(key) == nil)
    }
}
