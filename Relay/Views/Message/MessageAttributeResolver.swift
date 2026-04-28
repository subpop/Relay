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
import RelayInterface

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
    /// - Parameter pillStyle: The visual style for mention pills. Use
    ///   `.messageDefault` for incoming grey bubbles, `.messageWhiteText` for
    ///   outgoing blue or colored bubbles.
    static func applyColorOverrides(
        _ source: NSAttributedString,
        foreground: NSColor,
        linkColor: NSColor,
        pillStyle: MentionPillStyle = .messageDefault
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        let keys = NSAttributedString.Key.self
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        // Muted color for blockquote text content.
        let mutedForeground = foreground.withAlphaComponent(0.75)
        // Subtle color for the "|" bar character.
        let barColor = foreground.withAlphaComponent(0.25)

        // Collect mention link ranges for pill replacement (done after the
        // attribute pass to avoid mutating during enumeration).
        var mentionRanges: [(range: NSRange, url: URL, uri: MatrixURI, displayName: String)] = []

        result.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let hasLink = attrs[keys.link] != nil
            let isSpoiler = attrs[keys.matrixSpoiler] as? Bool == true
            let isBlockquoteBar = attrs[keys.blockquoteBar] as? Bool == true
            let isInBlockquote = attrs[keys.blockquoteDepth] != nil

            if isBlockquoteBar {
                result.addAttribute(keys.foregroundColor, value: barColor, range: range)
            } else if hasLink {
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
            } else if isInBlockquote, attrs[keys.foregroundColor] == nil {
                result.addAttribute(keys.foregroundColor, value: mutedForeground, range: range)
            } else if attrs[keys.foregroundColor] == nil {
                result.addAttribute(keys.foregroundColor, value: foreground, range: range)
            }

            // Ensure every range has a font.
            if attrs[keys.font] == nil {
                result.addAttribute(keys.font, value: baseFont, range: range)
            }
        }

        // Replace mention link ranges with PillTextAttachment images.
        // Process in reverse order so earlier ranges stay valid.
        for mention in mentionRanges.reversed() {
            let pill = PillTextAttachment(
                userId: mention.uri.identifier,
                displayName: mention.displayName,
                font: baseFont,
                style: pillStyle
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

        return result
    }
}
