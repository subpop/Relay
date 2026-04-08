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

/// Detects bare Matrix identifiers in an `AttributedString` and converts
/// them into clickable `https://matrix.to` links.
///
/// Recognizes room aliases (`#room:server`), user IDs (`@user:server`),
/// and room IDs (`!id:server`). Ranges that already carry a `.link`
/// attribute (e.g. from the Markdown parser or `NSDataDetector`) are
/// left untouched.
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
            let identifier = String(match.output.0)
            guard let attrRange = Range(match.range, in: result),
                  result[attrRange].link == nil,
                  let encoded = identifier.addingPercentEncoding(
                      withAllowedCharacters: .urlFragmentAllowed
                  ),
                  let url = URL(string: "https://matrix.to/#/\(encoded)")
            else { continue }
            result[attrRange].link = url
        }
    }
}
