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

import AppKit
import Foundation

/// Detects bare Matrix identifiers in attributed strings and converts
/// them into clickable `https://matrix.to` links.
///
/// Recognizes room aliases (`#room:server`), user IDs (`@user:server`),
/// and room IDs (`!id:server`). Ranges that already carry a `.link`
/// attribute (e.g. from the Markdown parser or an `<a>` tag) are
/// left untouched.
///
/// Run the linker *before* `NSDataDetector`: the detector mistakes the
/// server portion (e.g. `matrix.org` in `@user:matrix.org`) for a bare
/// URL, which would otherwise fragment the identifier.
enum MatrixIdentifierLinker {

    /// Regex matching Matrix identifiers: sigil + localpart + `:` + server
    /// (with optional port).
    ///
    /// Localpart characters follow the
    /// [Matrix spec appendix](https://spec.matrix.org/latest/appendices/#room-aliases):
    /// `[a-zA-Z0-9._=\-/]`.
    ///
    /// Server name: `[a-zA-Z0-9.\-]` with an optional `:[0-9]+` port suffix.
    private static let pattern = /[#@!][a-zA-Z0-9._=\-\/]+:[a-zA-Z0-9.\-]+(:[0-9]+)?/

    /// Scans `result` for bare Matrix identifiers that are not already
    /// linked, and sets their `.link` attribute to the corresponding
    /// `https://matrix.to` URL.
    static func linkify(_ result: inout AttributedString) {
        let plain = String(result.characters)
        for match in plain.matches(of: pattern) {
            let (identifier, stringRange) = trimmedMatch(
                String(match.output.0), range: match.range, in: plain
            )
            guard let attrRange = Range(stringRange, in: result),
                  !hasLink(in: result, range: attrRange),
                  let url = matrixToURL(for: identifier)
            else { continue }
            result[attrRange].link = url
        }
    }

    /// `NSMutableAttributedString` variant for the HTML parser path, which
    /// builds its result directly as `NSMutableAttributedString`.
    static func linkify(_ result: NSMutableAttributedString) {
        let plain = result.string
        for match in plain.matches(of: pattern) {
            let (identifier, stringRange) = trimmedMatch(
                String(match.output.0), range: match.range, in: plain
            )
            let nsRange = NSRange(stringRange, in: plain)
            guard nsRange.length > 0,
                  !hasLink(in: result, range: nsRange),
                  let url = matrixToURL(for: identifier)
            else { continue }
            result.addAttribute(.link, value: url, range: nsRange)
        }
    }

    /// Whether any character in `range` already carries a `.link` attribute.
    /// A slice-level check is insufficient: when only part of the range is
    /// linked (e.g. `NSDataDetector` claiming just `matrix.org`), the slice
    /// still reports `nil`.
    static func hasLink(
        in result: AttributedString, range: Range<AttributedString.Index>
    ) -> Bool {
        for run in result[range].runs where run.link != nil {
            return true
        }
        return false
    }

    /// Whether any character in `range` already carries a `.link` attribute.
    static func hasLink(in result: NSMutableAttributedString, range: NSRange) -> Bool {
        var found = false
        result.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Builds the `https://matrix.to` URL for an identifier, returning `nil`
    /// when the identifier does not round-trip as a recognized Matrix URI.
    private static func matrixToURL(for identifier: String) -> URL? {
        guard let encoded = identifier.addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed
        ),
              let url = URL(string: "https://matrix.to/#/\(encoded)"),
              MatrixURI(url: url) != nil
        else { return nil }
        return url
    }

    /// Strips trailing `.`/`-` characters (sentence punctuation, never valid
    /// at the end of a server name) from a regex match, shrinking its range
    /// to match. All trimmed characters are ASCII, so index arithmetic stays
    /// in bounds.
    private static func trimmedMatch(
        _ identifier: String, range: Range<String.Index>, in plain: String
    ) -> (String, Range<String.Index>) {
        var identifier = identifier
        var end = range.upperBound
        while let last = identifier.last, last == "." || last == "-" {
            identifier.removeLast()
            end = plain.index(before: end)
        }
        return (identifier, range.lowerBound..<end)
    }
}
