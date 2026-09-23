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
import os


private let logger = Logger(subsystem: "RelayShared", category: "PendingShareStore")

/// Manages pending share records and files in the app group container.
///
/// The share extension writes shared files and ``PendingShare`` records to the
/// app group container. The main app reads them, sends the attachments, and
/// removes the records once complete.
public enum PendingShareStore: Sendable {

    /// The name of the directory inside the app group container that holds
    /// pending share files.
    private static let pendingSharesDirectory = {
        #if DEBUG
        "pending-shares-debug"
        #else
        "pending-shares"
        #endif
    }()

    /// The filename for the JSON manifest of pending share records.
    private static let manifestFilename = {
        #if DEBUG
        "pending-shares-debug.json"
        #else
        "pending-shares.json"
        #endif
    }()

    /// The name of the file inside the app group container that holds the
    /// room list cache for the share extension.
    private static let roomCacheFilename = {
        #if DEBUG
        "shareable-rooms-debug.json"
        #else
        "shareable-rooms.json"
        #endif
    }()

    /// The name of the signal file the share extension writes (and the main
    /// app reads, then deletes) to hand off the latest pending share ID.
    public static let signalFilename = {
        #if DEBUG
        "latest-share-id-debug.txt"
        #else
        "latest-share-id.txt"
        #endif
    }()

    // MARK: - Container URLs

    /// Returns the directory URL for pending share files, creating it if needed.
    static var pendingSharesDirectoryURL: URL? {
        guard let container = AppGroup.containerURL else {
            logger.error("App group container not available")
            return nil
        }
        let url = container.appending(
            path: pendingSharesDirectory,
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create pending shares directory: \(error)")
            return nil
        }
        return url
    }

    // MARK: - Pending Share Records

    /// Saves a pending share record to the manifest.
    public static func save(_ share: PendingShare) {
        var all = loadAll()
        all.append(share)
        writeManifest(all)
    }

    /// Loads all pending share records.
    public static func loadAll() -> [PendingShare] {
        guard let container = AppGroup.containerURL else { return [] }
        let manifestURL = container.appending(path: manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        do {
            return try JSONDecoder().decode([PendingShare].self, from: data)
        } catch {
            logger.error("Failed to decode pending shares manifest: \(error)")
            return []
        }
    }

    /// Removes a pending share record by ID and deletes its associated files.
    public static func remove(id: UUID) {
        var all = loadAll()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let share = all.remove(at: index)
        writeManifest(all)

        // Clean up the shared files.
        guard let dir = pendingSharesDirectoryURL else { return }
        for filename in share.filenames {
            let fileURL = dir.appending(path: filename)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Returns the full file URL for a pending share's file within the container.
    public static func fileURL(for filename: String) -> URL? {
        pendingSharesDirectoryURL?.appending(path: filename)
    }

    private static func writeManifest(_ shares: [PendingShare]) {
        guard let container = AppGroup.containerURL else { return }
        let manifestURL = container.appending(path: manifestFilename)
        do {
            let data = try JSONEncoder().encode(shares)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            logger.error("Failed to write pending shares manifest: \(error)")
        }
    }

    // MARK: - Room Cache

    /// Writes the shareable room list cache to the app group container.
    ///
    /// Called by the main app after the room list is loaded or updated so the
    /// share extension has a recent snapshot of available rooms.
    public static func writeRoomCache(_ rooms: [ShareableRoom]) {
        guard let container = AppGroup.containerURL else { return }
        let cacheURL = container.appending(path: roomCacheFilename)
        do {
            let data = try JSONEncoder().encode(rooms)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            logger.error("Failed to write room cache: \(error)")
        }
    }

    /// Loads the shareable room list cache from the app group container.
    ///
    /// Called by the share extension on launch to display the room picker.
    public static func loadRoomCache() -> [ShareableRoom] {
        guard let container = AppGroup.containerURL else { return [] }
        let cacheURL = container.appending(path: roomCacheFilename)
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        do {
            return try JSONDecoder().decode([ShareableRoom].self, from: data)
        } catch {
            logger.error("Failed to decode room cache: \(error)")
            return []
        }
    }
}
