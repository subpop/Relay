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

    /// Identity of the item, without accessibility or keychain-selection
    /// attributes, so it matches items written by earlier versions.
    private func identity(for key: KeyStoreKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Self.servicePrefix).\(key.service)",
            kSecAttrAccount as String: key.account,
            kSecAttrAccessGroup as String: RelayShared.AppGroup.identifier,
        ]
    }

    /// Items live in the data-protection keychain, where the
    /// accessibility attribute is enforced.
    private func query(for key: KeyStoreKey) -> [String: Any] {
        var query = identity(for: key)
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private func read(_ query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    /// Adds or updates the item and reports whether a new item was added.
    @discardableResult
    private func store(_ data: Data, for key: KeyStoreKey) throws -> Bool {
        // Add-or-update, never delete-then-add: a crash or kill between
        // the delete and the add would silently destroy the stored value
        // (e.g. the session), stranding the next launch logged out.
        var attributes = query(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(attributes as CFDictionary, nil)
        let added = status == errSecSuccess
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                query(for: key) as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
        return added
    }

    func save(_ data: Data, for key: KeyStoreKey) async throws {
        try store(data, for: key)
    }

    /// Loads the item, moving one written by an earlier version (outside
    /// the data-protection keychain, or with a syncable accessibility
    /// class) into the current form.
    func load(_ key: KeyStoreKey) async throws -> Data? {
        if let data = read(query(for: key)) {
            return data
        }
        guard let legacy = read(identity(for: key)) else { return nil }
        // Only a newly added item proves the legacy one lives elsewhere;
        // on a duplicate the store updated it in place and deleting the
        // legacy query would remove the migrated item.
        if (try? store(legacy, for: key)) == true {
            SecItemDelete(identity(for: key) as CFDictionary)
            if read(query(for: key)) == nil {
                _ = try? store(legacy, for: key)
            }
        }
        return legacy
    }

    func delete(_ key: KeyStoreKey) async throws {
        SecItemDelete(query(for: key) as CFDictionary)
        SecItemDelete(identity(for: key) as CFDictionary)
    }
}
