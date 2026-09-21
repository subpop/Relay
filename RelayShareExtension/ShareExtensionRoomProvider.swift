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
import RelayShared

/// Loads the cached room list from the app group container for the share extension.
///
/// The main app writes this cache periodically via ``PendingShareStore/writeRoomCache(_:)``.
/// The share extension reads it on launch to display a room picker without needing
/// to initialise the Matrix SDK.
enum ShareExtensionRoomProvider {
    private static let roomCacheFilename = {
        #if DEBUG
        "shareable-rooms-debug.json"
        #else
        "shareable-rooms.json"
        #endif
    }()

    /// Loads the cached room list, sorted by most recent activity.
    static func loadRooms() -> [ShareableRoom] {
        guard let container = AppGroup.containerURL else { return [] }
        let cacheURL = container.appending(path: roomCacheFilename)
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }

        let rooms = (try? JSONDecoder().decode([ShareableRoom].self, from: data)) ?? []
        return rooms.sorted { lhs, rhs in
            (lhs.lastActivityTimestamp ?? .distantPast) > (rhs.lastActivityTimestamp ?? .distantPast)
        }
    }
}
