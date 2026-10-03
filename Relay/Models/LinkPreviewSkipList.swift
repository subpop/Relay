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

/// A hidden, `UserDefaults`-backed list of domains to never show link
/// previews for. There's no Settings UI for this; see the README's
/// "Advanced Configuration" section for how to set it via `defaults write`.
enum LinkPreviewSkipList {
    static let storageKey = "linkPreview.skippedDomains"

    private static let defaults = UserDefaults.standard

    /// Normalized (trimmed, lowercased, non-empty) skipped domains.
    static func domains() -> [String] {
        (defaults.array(forKey: storageKey) as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Whether `url`'s host matches a skipped domain or one of its subdomains.
    static func isSkipped(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return domains().contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
