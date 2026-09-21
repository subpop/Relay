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

/// Adds user deep-links to system-event descriptions.
///
/// MatrixKit supplies plain description strings plus raw identifiers
/// (sender, membership target). This linker wraps the display names in
/// `https://matrix.to` user links — the same links message mentions use —
/// so `SystemEventView`'s existing `openURL` interception routes taps to
/// the member inspector. Names that can't be resolved to a user stay
/// plain text.
enum SystemEventLinker {

    /// Returns `description` with user links on the sender's and (when
    /// present and different) the membership target's names.
    ///
    /// - Parameters:
    ///   - description: Plain description built by MatrixKit.
    ///   - senderName: Sender display name, if known.
    ///   - senderID: Sender's Matrix user ID.
    ///   - targetName: Membership target display name, if known.
    ///   - targetID: Membership target's Matrix user ID, if the target
    ///     differs from the sender.
    static func linkedDescription(
        _ description: String,
        senderName: String?,
        senderID: String,
        targetName: String?,
        targetID: String?
    ) -> AttributedString {
        var result = AttributedString(description)
        let senderLabel = label(senderName, fallback: senderID)
        guard let targetID, targetID != senderID else {
            linkAllOccurrences(of: [(senderLabel, senderID), (senderID, senderID)], in: &result, of: description)
            return result
        }
        let targetLabel = label(targetName, fallback: targetID)
        if senderLabel == targetLabel {
            // Identical display names: the leading mention is the actor,
            // trailing mentions are the target.
            linkAnchoredOccurrences(
                of: senderLabel, senderID: senderID, targetID: targetID,
                in: &result, of: description)
            return result
        }
        linkAllOccurrences(
            of: [(senderLabel, senderID), (senderID, senderID), (targetLabel, targetID), (targetID, targetID)],
            in: &result, of: description)
        return result
    }

    // MARK: - Helpers

    private static func label(_ name: String?, fallback: String) -> String {
        guard let name, !name.isEmpty else { return fallback }
        return name
    }

    /// Links every occurrence of each name, longest names first so a
    /// shorter name can't claim part of a longer one. Ranges already
    /// linked are left untouched.
    private static func linkAllOccurrences(
        of links: [(name: String, userID: String)],
        in result: inout AttributedString,
        of plain: String
    ) {
        var seen: Set<String> = []
        for (name, userID) in links.sorted(by: { $0.name.count > $1.name.count }) {
            guard seen.insert("\(name)\u{0}\(userID)").inserted else { continue }
            for range in ranges(of: name, in: plain) {
                link(range, to: userID, in: &result)
            }
        }
    }

    /// Links the first occurrence of a shared display name to the sender
    /// and the rest to the target, then links any raw user-ID occurrences.
    private static func linkAnchoredOccurrences(
        of name: String,
        senderID: String,
        targetID: String,
        in result: inout AttributedString,
        of plain: String
    ) {
        let occurrences = ranges(of: name, in: plain)
        if let first = occurrences.first {
            link(first, to: senderID, in: &result)
        }
        for range in occurrences.dropFirst() {
            link(range, to: targetID, in: &result)
        }
        linkAllOccurrences(
            of: [(senderID, senderID), (targetID, targetID)],
            in: &result, of: plain)
    }

    private static func link(_ range: Range<String.Index>, to userID: String, in result: inout AttributedString) {
        guard
            let attrRange = Range(range, in: result),
            result[attrRange].link == nil,
            let url = userLink(for: userID)
        else { return }
        result[attrRange].link = url
    }

    private static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = haystack.startIndex
        while from < haystack.endIndex,
              let found = haystack.range(of: needle, range: from..<haystack.endIndex)
        {
            if !isEmbedded(found, in: haystack) {
                out.append(found)
            }
            from = found.upperBound
        }
        return out
    }

    /// Whether the match sits inside a longer alphanumeric run (e.g.
    /// "Alice" within "Alicia") rather than standing alone.
    private static func isEmbedded(_ range: Range<String.Index>, in haystack: String) -> Bool {
        if range.lowerBound > haystack.startIndex {
            let prev = haystack[haystack.index(before: range.lowerBound)]
            if prev.isLetter || prev.isNumber { return true }
        }
        if range.upperBound < haystack.endIndex {
            let next = haystack[range.upperBound]
            if next.isLetter || next.isNumber { return true }
        }
        return false
    }

    private static func userLink(for userID: String) -> URL? {
        guard let encoded = userID.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return nil
        }
        return URL(string: "https://matrix.to/#/\(encoded)")
    }
}
