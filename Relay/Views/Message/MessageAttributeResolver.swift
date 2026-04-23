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
    static func applyColorOverrides(
        _ source: NSAttributedString,
        foreground: NSColor,
        linkColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        let keys = NSAttributedString.Key.self
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        // Muted color for blockquote text content.
        let mutedForeground = foreground.withAlphaComponent(0.75)
        // Subtle color for the "|" bar character.
        let barColor = foreground.withAlphaComponent(0.25)

        result.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let hasLink = attrs[keys.link] != nil
            let isSpoiler = attrs[keys.matrixSpoiler] as? Bool == true
            let isBlockquoteBar = attrs[keys.blockquoteBar] as? Bool == true
            let isInBlockquote = attrs[keys.blockquoteDepth] != nil

            if isBlockquoteBar {
                result.addAttribute(keys.foregroundColor, value: barColor, range: range)
            } else if hasLink {
                result.addAttribute(keys.foregroundColor, value: linkColor, range: range)

                // Apply pill styling to matrix.to user and room links.
                if let url = attrs[keys.link] as? URL,
                   let uri = MatrixURI(url: url),
                   uri.isUser || uri.isRoom {
                    let pillColor = linkColor.withAlphaComponent(0.35)
                    result.addAttributes([
                        .mentionPillColor: pillColor,
                        .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .medium)
                    ], range: range)
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

        insertPillSpacing(result)

        return result
    }

    /// Inserts thin spaces inside the pill-attributed range at each edge so
    /// the capsule background has visual padding around the mention text.
    /// The `PillLayoutManager` handles the external gap by insetting the
    /// drawn capsule from the full glyph rect.
    private static func insertPillSpacing(_ result: NSMutableAttributedString) {
        // U+2009 THIN SPACE for internal pill padding.
        let thinSpace = "\u{2009}"

        var pillRanges: [NSRange] = []
        let keys = NSAttributedString.Key.self
        result.enumerateAttribute(
            keys.mentionPillColor,
            in: NSRange(location: 0, length: result.length),
            options: []
        ) { value, range, _ in
            if value != nil {
                pillRanges.append(range)
            }
        }

        // Insert in reverse order so earlier ranges stay valid.
        // Two thin spaces on each side: the outer one sits outside the drawn
        // capsule (external gap, via PillLayoutManager's pillHorizontalInset),
        // the inner one sits inside the capsule (internal padding).
        for range in pillRanges.reversed() {
            let pillAttrs = result.attributes(at: range.location, effectiveRange: nil)
            let spacer = NSAttributedString(string: thinSpace + thinSpace + thinSpace, attributes: pillAttrs)

            // Trailing spacers (inside pill range).
            result.insert(spacer, at: range.location + range.length)
            // Leading spacers (inside pill range).
            result.insert(spacer, at: range.location)
        }
    }
}
