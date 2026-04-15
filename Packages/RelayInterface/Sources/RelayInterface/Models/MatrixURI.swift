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

/// A parsed Matrix URI representing a room, user, or event reference.
///
/// Supports both the standard `matrix:` URI scheme
/// ([MSC2312](https://github.com/matrix-org/matrix-spec-proposals/blob/main/proposals/2312-matrix-uri.md),
/// Matrix spec v1.2+) and legacy `https://matrix.to` navigation links.
///
/// ## `matrix:` URI Examples
///
/// ```
/// matrix:r/somewhere:example.org             → #somewhere:example.org
/// matrix:roomid/somewhere:example.org        → !somewhere:example.org
/// matrix:u/alice:example.org                 → @alice:example.org
/// matrix:roomid/room:server/e/event          → event permalink
/// ```
///
/// ## `matrix.to` URL Examples
///
/// ```
/// https://matrix.to/#/#somewhere:example.org
/// https://matrix.to/#/!room:example.org
/// https://matrix.to/#/@alice:example.org
/// https://matrix.to/#/!room:example.org/$event:example.org
/// ```
public enum MatrixURI: Equatable, Sendable {
    /// A room referenced by its alias (e.g. `#somewhere:example.org`).
    case room(alias: String, via: [String])

    /// A room referenced by its ID (e.g. `!abc123:example.org`).
    case roomId(id: String, via: [String])

    /// A user referenced by their Matrix ID (e.g. `@alice:example.org`).
    case user(id: String)

    /// An event permalink within a room.
    case event(roomId: String, eventId: String, via: [String])

    /// The primary Matrix identifier with its sigil (e.g. `"#room:server"`, `"!id:server"`, `"@user:server"`).
    public var identifier: String {
        switch self {
        case .room(let alias, _): alias
        case .roomId(let id, _): id
        case .user(let id): id
        case .event(let roomId, _, _): roomId
        }
    }

    /// Whether this URI references a user (`@user:server`).
    public var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    /// Attempts to parse a URL as a `matrix:` URI or `https://matrix.to` link.
    ///
    /// - Parameter url: The URL to parse.
    /// - Returns: A ``MatrixURI`` value, or `nil` if the URL is not a recognized Matrix link.
    public init?(url: URL) {
        if url.scheme == "matrix" {
            self.init(matrixSchemeURL: url)
        } else if url.scheme == "https", url.host?.lowercased() == "matrix.to" {
            self.init(matrixToURL: url)
        } else {
            return nil
        }
    }

    // MARK: - matrix: URI Parsing

    /// Parses a `matrix:` scheme URI.
    ///
    /// The path format is `{type}/{id}[/{type}/{id}]`, where type is one of:
    /// - `r` — room alias (sigil `#`)
    /// - `roomid` — room ID (sigil `!`)
    /// - `u` — user (sigil `@`)
    /// - `e` — event (sigil `$`), nested under a room
    private init?(matrixSchemeURL url: URL) {
        // URL path for "matrix:r/somewhere:example.org" gives "r/somewhere:example.org"
        // depending on the URL parser. We need to handle both URL.path and opaque URI forms.
        let raw: String
        if #available(macOS 13.0, *) {
            // On modern macOS, `URL.path()` returns the path without percent-encoding.
            // For opaque URIs like "matrix:r/foo:bar", absoluteString minus scheme is the path.
            let abs = url.absoluteString
            if let schemeEnd = abs.range(of: "matrix:") {
                raw = String(abs[schemeEnd.upperBound...])
            } else {
                return nil
            }
        } else {
            let abs = url.absoluteString
            if let schemeEnd = abs.range(of: "matrix:") {
                raw = String(abs[schemeEnd.upperBound...])
            } else {
                return nil
            }
        }

        // Split off query string.
        let pathPart: String
        let queryPart: String?
        if let queryStart = raw.firstIndex(of: "?") {
            pathPart = String(raw[raw.startIndex..<queryStart])
            queryPart = String(raw[raw.index(after: queryStart)...])
        } else {
            pathPart = raw
            queryPart = nil
        }

        let via = Self.parseVia(query: queryPart)
        let segments = pathPart.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard segments.count >= 2 else { return nil }

        let entityType = segments[0]
        let entityId = Self.decode(segments[1])

        switch entityType {
        case "r":
            // Room alias: matrix:r/somewhere:example.org → #somewhere:example.org
            self = .room(alias: "#\(entityId)", via: via)

        case "roomid":
            // Room ID: matrix:roomid/somewhere:example.org → !somewhere:example.org
            if segments.count >= 4, segments[2] == "e" {
                // Event permalink: matrix:roomid/room:server/e/event
                let eventId = Self.decode(segments[3])
                self = .event(roomId: "!\(entityId)", eventId: "$\(eventId)", via: via)
            } else {
                self = .roomId(id: "!\(entityId)", via: via)
            }

        case "u":
            // User: matrix:u/alice:example.org → @alice:example.org
            self = .user(id: "@\(entityId)")

        default:
            return nil
        }
    }

    // MARK: - matrix.to URL Parsing

    /// Parses a `https://matrix.to/#/...` URL.
    ///
    /// The fragment contains the identifier (with sigil) and optional event ID suffix.
    /// Query parameters (`?via=server`) may be on the URL or within the fragment.
    private init?(matrixToURL url: URL) {
        guard let fragment = url.fragment, fragment.hasPrefix("/") else { return nil }

        var raw = String(fragment.dropFirst())

        // Extract query parameters from the fragment or the URL itself.
        let queryPart: String?
        if let queryStart = raw.firstIndex(of: "?") {
            queryPart = String(raw[raw.index(after: queryStart)...])
            raw = String(raw[raw.startIndex..<queryStart])
        } else {
            queryPart = url.query
        }

        let via = Self.parseVia(query: queryPart)

        // Strip event permalink suffix (/$eventId).
        var eventIdRaw: String?
        if let eventStart = raw.range(of: "/\\$", options: .regularExpression) {
            eventIdRaw = String(raw[raw.index(after: eventStart.lowerBound)...])
            raw = String(raw[raw.startIndex..<eventStart.lowerBound])
        }

        let identifier = Self.decode(raw)

        if identifier.hasPrefix("@") {
            self = .user(id: identifier)
        } else if identifier.hasPrefix("!") {
            if let eventId = eventIdRaw.map(Self.decode) {
                self = .event(roomId: identifier, eventId: eventId, via: via)
            } else {
                self = .roomId(id: identifier, via: via)
            }
        } else if identifier.hasPrefix("#") {
            self = .room(alias: identifier, via: via)
        } else {
            return nil
        }
    }

    // MARK: - Helpers

    /// Extracts `via` parameter values from a query string.
    private static func parseVia(query: String?) -> [String] {
        guard let query else { return [] }
        return query
            .split(separator: "&")
            .compactMap { param -> String? in
                let parts = param.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0] == "via" else { return nil }
                return String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
    }

    /// Percent-decodes a string.
    private static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
