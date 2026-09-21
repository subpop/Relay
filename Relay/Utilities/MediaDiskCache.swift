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
/// Directory, key formats, and SHA-256 filenames intentionally match the
/// pre-migration media cache, so bytes cached by previous installs are
/// reused instead of re-downloaded (or lost when the server prunes them).
/// All file I/O runs on this actor, off the main thread. Errors are
/// silently ignored: a miss simply falls through to network.
actor MediaDiskCache {
    static let shared = MediaDiskCache()

    /// The on-disk cache directory for media files.
    private let directory: URL = {
        #if DEBUG
        let subdirectory = "Relay/media-cache-debug"
        #else
        let subdirectory = "Relay/media-cache"
        #endif
        let url = URL.cachesDirectory.appending(
            path: subdirectory, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

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
