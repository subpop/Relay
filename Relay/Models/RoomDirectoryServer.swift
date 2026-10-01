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

/// An additional room-directory server browsable through the logged-in
/// homeserver (federation-backed directory lookup, e.g. `matrixrooms.info`).
///
/// The logged-in homeserver itself is never stored here: it is derived live
/// from the session, always listed first, and can be neither removed nor
/// disabled.
struct RoomDirectoryServer: Codable, Identifiable, Hashable {
    var id: UUID
    /// Bare server name (`host` or `host:port`), without scheme or path.
    var serverName: String
    var isEnabled: Bool

    init(id: UUID = UUID(), serverName: String, isEnabled: Bool = true) {
        self.id = id
        self.serverName = serverName
        self.isEnabled = isEnabled
    }
}

/// Persistence and normalization for extra room-directory servers.
///
/// Stored globally in `UserDefaults` as JSON. When nothing has been stored
/// yet, the directory ships with `matrixrooms.info` enabled.
enum RoomDirectoryStore {
    /// The directory server shipped by default (matrixrooms.info).
    static let defaultServerName = "matrixrooms.info"

    private static let storageKey = "directory.servers"
    private static let defaults = UserDefaults.standard

    /// Extra servers, seeding the default when nothing is stored yet.
    static func load() -> [RoomDirectoryServer] {
        guard let data = defaults.data(forKey: storageKey) else {
            return [RoomDirectoryServer(serverName: defaultServerName)]
        }
        guard let servers = try? JSONDecoder().decode([RoomDirectoryServer].self, from: data) else {
            return [RoomDirectoryServer(serverName: defaultServerName)]
        }
        return servers
    }

    static func save(_ servers: [RoomDirectoryServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Normalize user input to a bare server name, or nil when invalid.
    ///
    /// Strips schemes (`https://`), paths, query strings, fragments, and
    /// surrounding whitespace. Keeps an explicit port (`host:port`).
    static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        for separator in ["/", "?", "#"] {
            if let index = text.firstIndex(of: Character(separator)) {
                text = String(text[..<index])
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" "), text.contains(".") || text.contains(":") else {
            return nil
        }
        return text
    }
}
