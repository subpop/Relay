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

/// Keychain-backed `KeyStore` for MatrixKit crypto material (device keys,
/// one-time keys, session blobs).
///
/// Keys map straight onto keychain (`service`, `account`) identity, in the
/// app's access group so the share extension could read them if needed.
struct KeychainKeyStore: KeyStore {
    enum KeychainError: Error {
        case saveFailed(OSStatus)
    }

    private static var servicePrefix: String {
        #if DEBUG
        "app.subpop.Relay.crypto.debug"
        #else
        "app.subpop.Relay.crypto"
        #endif
    }

    private func query(for key: KeyStoreKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Self.servicePrefix).\(key.service)",
            kSecAttrAccount as String: key.account,
            kSecAttrAccessGroup as String: RelayShared.AppGroup.identifier,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
    }

    func save(_ data: Data, for key: KeyStoreKey) async throws {
        var query = query(for: key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func load(_ key: KeyStoreKey) async throws -> Data? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    func delete(_ key: KeyStoreKey) async throws {
        SecItemDelete(query(for: key) as CFDictionary)
    }
}
