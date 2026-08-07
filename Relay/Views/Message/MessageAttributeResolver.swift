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
import RelayInterface
import SwiftUI

// MARK: - Attribute Resolution

extension MessageTextView {
    /// Applies foreground and link color overrides to a parsed `NSAttributedString`,
    /// respecting any existing custom colors (e.g. `data-mx-color`). Works for both
    /// HTML-parsed and markdown-parsed attributed strings.
    ///
    /// Matrix mention links (`matrix.to` user and room links) are replaced with
    /// inline ``PillTextAttachment`` images rendered from ``MentionPillView``.
    /// The `.link` attribute is preserved on the attachment character so that
    /// click-to-navigate still works via ``MessageTextContent``.
    ///
    /// When `highlightedUserId` is set, the mention pill matching that user is
    /// rendered with the `.highlightedMention` style (red pill). When
    /// `highlightKeywords` is non-empty, matching text is replaced with
    /// non-clickable red keyword pills.
    ///
    /// - Parameter pillStyle: The visual style for mention pills. Use
    ///   `.messageDefault` for incoming grey bubbles, `.messageWhiteText` for
    ///   outgoing blue or colored bubbles.
    static func applyColorOverrides(
        _ source: NSAttributedString,
        foreground: NSColor,
        linkColor: NSColor,
        pillStyle: MentionPillStyle = .messageDefault,
        highlightedUserId: String? = nil,
        highlightKeywords: [String] = []
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        let keys = NSAttributedString.Key.self
        let baseFont = MessageTextScale.baseFont

        // Collect mention link ranges for pill replacement (done after the
        // attribute pass to avoid mutating during enumeration).
        var mentionRanges: [(range: NSRange, url: URL, uri: MatrixURI, displayName: String)] = []

        result.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let hasLink = attrs[keys.link] != nil
            let isSpoiler = attrs[keys.matrixSpoiler] as? Bool == true
            let isBlockquoteMarker = attrs[keys.blockquoteMarker] as? Bool == true

            if hasLink {
                result.addAttribute(keys.foregroundColor, value: linkColor, range: range)
                result.addAttribute(
                    keys.underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )

                // Record matrix.to user and room links for pill replacement.
                if let url = attrs[keys.link] as? URL,
                   let uri = MatrixURI(url: url),
                   uri.isUser || uri.isRoom {
                    let displayName = result.attributedSubstring(from: range).string
                    mentionRanges.append((range, url, uri, displayName))
                }
            } else if isSpoiler {
                // Keep spoiler coloring as-is.
            } else if isBlockquoteMarker {
                // Replaced with the quote icon attachment below.
            } else if attrs[keys.foregroundColor] == nil {
                result.addAttribute(keys.foregroundColor, value: foreground, range: range)
            }

            // Ensure every range has a font.
            if attrs[keys.font] == nil {
                result.addAttribute(keys.font, value: baseFont, range: range)
            }
        }

        // Replace blockquote markers with tinted quote icon attachments.
        // Process in reverse order so earlier ranges stay valid.
        var markerRanges: [NSRange] = []
        result.enumerateAttribute(keys.blockquoteMarker, in: fullRange, options: []) { value, range, _ in
            if (value as? Bool) == true {
                markerRanges.append(range)
            }
        }
        for range in markerRanges.reversed() {
            let icon = QuoteTextAttachment(
                fontSize: baseFont.pointSize,
                tint: Color(nsColor: foreground.withAlphaComponent(0.6))
            )
            let replacement = NSMutableAttributedString(attachment: icon)
            replacement.addAttributes(
                result.attributes(at: range.location, effectiveRange: nil),
                range: NSRange(location: 0, length: replacement.length)
            )
            result.replaceCharacters(in: range, with: replacement)
        }

        // Replace mention link ranges with PillTextAttachment images.
        // Process in reverse order so earlier ranges stay valid.
        for mention in mentionRanges.reversed() {
            let isHighlightedUser = highlightedUserId != nil
                && mention.uri.isUser
                && mention.uri.identifier == highlightedUserId
            let pill = PillTextAttachment(
                userId: mention.uri.identifier,
                displayName: mention.displayName,
                font: baseFont,
                style: isHighlightedUser ? .highlightedMention : pillStyle
            )
            let attachmentString = NSMutableAttributedString(attachment: pill)
            // Preserve the .link attribute so click-to-navigate still works.
            attachmentString.addAttributes([
                .link: mention.url,
                .mentionUserID: mention.uri.identifier,
                .mentionDisplayName: mention.displayName,
            ], range: NSRange(location: 0, length: attachmentString.length))
            result.replaceCharacters(in: mention.range, with: attachmentString)
        }

        // Replace keyword matches with highlighted pill attachments.
        // Collected first, then replaced in reverse order so ranges stay valid.
        if !highlightKeywords.isEmpty {
            var keywordRanges: [(range: NSRange, text: String)] = []
            let plainText = result.string
            for keyword in highlightKeywords {
                var searchRange = plainText.startIndex..<plainText.endIndex
                while let matchRange = plainText.range(
                    of: keyword, options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                ) {
                    let nsRange = NSRange(matchRange, in: plainText)
                    let matchedText = String(plainText[matchRange])
                    keywordRanges.append((nsRange, matchedText))
                    searchRange = matchRange.upperBound..<plainText.endIndex
                }
            }
            for match in keywordRanges.sorted(by: { $0.range.location > $1.range.location }) {
                let pill = PillTextAttachment(
                    keyword: match.text, font: baseFont, style: .highlightedMention
                )
                let attachmentString = NSMutableAttributedString(attachment: pill)
                result.replaceCharacters(in: match.range, with: attachmentString)
            }
        }

        return result
    }
}
