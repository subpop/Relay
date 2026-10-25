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

/// File-backed media cache shared by avatars, thumbnails, and downloads.
///
/// Entries are kept so media still resolves after the server prunes it.
/// Content from encrypted attachments is stored as received (still
/// encrypted) under `encryptedKey(_:)` and decrypted by the caller on
/// every read, so no plaintext of end-to-end encrypted media rests on
/// disk. All file I/O runs on this actor, off the main thread. Errors are
/// silently ignored: a miss simply falls through to network.
actor MediaDiskCache {
    static let shared = MediaDiskCache()

    /// The on-disk cache directory for media files.
    private let directory: URL = {
        #if DEBUG
        let name = "media-cache-debug"
        #else
        let name = "media-cache"
        #endif
        // The unversioned directory may hold decrypted attachments.
        try? FileManager.default.removeItem(
            at: URL.cachesDirectory.appending(
                path: "Relay/\(name)", directoryHint: .isDirectory))
        let url = URL.cachesDirectory.appending(
            path: "Relay/\(name)-v2", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Cache key for the still-encrypted bytes of an encrypted attachment,
    /// kept apart from plaintext entries for the same MXC URI.
    nonisolated static func encryptedKey(_ key: String) -> String {
        "encrypted:\(key)"
    }

    /// SHA-256 hex digest of the cache key, safe for use as a filename.
    private nonisolated func filename(for key: String) -> String {
        CryptoKit.SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Reads data from the on-disk cache, returning `nil` on miss.
    func read(key: String) -> Data? {
        let path = directory.appending(path: filename(for: key))
        return try? Data(contentsOf: path)
    }

    /// Writes data to the on-disk cache. Errors are silently ignored.
    func write(key: String, data: Data) {
        let path = directory.appending(path: filename(for: key))
        try? data.write(to: path, options: .atomic)
    }
}
