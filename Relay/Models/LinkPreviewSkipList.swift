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

/// A `UserDefaults`-backed list of domains whose link previews omit thumbnails.
enum LinkPreviewSkipList {
    static let storageKey = "linkPreview.skippedDomains"
    static let revisionKey = "linkPreview.skippedDomainsRevision"

    private static let defaults = UserDefaults.standard

    /// Normalized (trimmed, lowercased, non-empty, unique) excluded domains.
    static func domains() -> [String] {
        normalizedDomains(defaults.array(forKey: storageKey) as? [String] ?? [])
    }

    /// Saves the excluded domains and invalidates views that depend on them.
    static func setDomains(_ domains: [String]) {
        defaults.set(normalizedDomains(domains), forKey: storageKey)
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }

    private static func normalizedDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether `url`'s host matches an excluded domain or one of its subdomains.
    static func excludesThumbnail(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return domains().contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
