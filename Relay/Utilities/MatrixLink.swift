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

/// A parsed Matrix deep link, derived from either a `https://matrix.to` URL or a `matrix:` URI.
///
/// **matrix.to format:**
/// - User:  `https://matrix.to/#/@user:server`
/// - Room:  `https://matrix.to/#/#room:server` or `https://matrix.to/#/!roomId:server`
///
/// **matrix: URI format (MSC2312):**
/// - User:  `matrix:u/user:server`
/// - Room:  `matrix:r/room:server` or `matrix:roomid/roomId:server`
enum MatrixLink {
    /// A Matrix user ID (e.g. `@alice:matrix.org`).
    case user(String)
    /// A room alias or room ID (e.g. `#general:matrix.org` or `!abc123:matrix.org`).
    case room(String)

    /// Parses a URL into a ``MatrixLink``, returning `nil` if the URL is not a recognised Matrix link.
    init?(url: URL) {
        if url.host?.lowercased() == "matrix.to" {
            guard let link = Self(matrixToURL: url) else { return nil }
            self = link
        } else if url.scheme?.lowercased() == "matrix" {
            guard let link = Self(matrixURI: url) else { return nil }
            self = link
        } else {
            return nil
        }
    }

    // MARK: - Private parsers

    private init?(matrixToURL url: URL) {
        // Fragment is everything after `#`, e.g. `/@alice:matrix.org` or `/#general:matrix.org`
        guard let fragment = url.fragment, fragment.hasPrefix("/") else { return nil }
        // The fragment may contain additional path components (e.g. an event ID after a second `/`).
        // Extract only the first component as the entity identifier.
        guard let entity = String(fragment.dropFirst())
            .components(separatedBy: "/").first?
            .removingPercentEncoding else { return nil }

        if entity.hasPrefix("@") {
            self = .user(entity)
        } else if entity.hasPrefix("#") || entity.hasPrefix("!") {
            self = .room(entity)
        } else {
            return nil
        }
    }

    private init?(matrixURI url: URL) {
        // matrix: URIs encode the entity type and identifier in the path:
        // `u/user:server`, `r/room:server`, `roomid/roomId:server` (without sigils)
        let path = url.path
        let parts = path.components(separatedBy: "/")
        guard parts.count >= 2 else { return nil }
        let type = parts[0]
        let identifier = parts[1]
        guard !identifier.isEmpty else { return nil }

        switch type {
        case "u":
            self = .user("@\(identifier)")
        case "r":
            self = .room("#\(identifier)")
        case "roomid":
            self = .room("!\(identifier)")
        default:
            return nil
        }
    }
}
