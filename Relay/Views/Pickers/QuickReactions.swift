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
import EmojiKit

/// The grid of "top" emoji reactions shown in the message bubble context
/// menu, iMessage-style, so a reaction can be added without opening the
/// full ``ReactionPickerCapsule``/``EmojiCatalogPopover``.
///
/// Backed by EmojiKit's persisted `.frequent` category, which both the
/// capsule and the catalog already feed via `EmojiGrid`'s default
/// `addSelectedEmojisTo`. Taps from the context menu bypass those grids,
/// so ``record(_:)`` feeds the same category directly.
enum QuickReactions {
    /// Number of columns per palette row.
    static let columns = 6

    /// Number of palette rows shown in the menu.
    static let rows = 2

    /// Seed/fallback emoji, used to pad out the grid before the user has
    /// built up any reaction history. Matches the set suggested in #192.
    static let defaults = ["❤️", "👍", "👎", "😂", "🙏", "🤔", "😮", "😢", "🎉", "🔥", "👏", "💯"]

    /// The top emoji, chunked into ``rows`` rows of ``columns`` each.
    ///
    /// Starts with the user's most-frequently-used emoji (most frequent
    /// first), then pads with ``defaults`` to fill the grid, skipping any
    /// default already present.
    static func top() -> [[String]] {
        let frequent = EmojiCategory.Persisted.frequent.getEmojis().map(\.char)
        var seen = Set(frequent)
        var combined = frequent
        for emoji in defaults where combined.count < columns * rows && !seen.contains(emoji) {
            combined.append(emoji)
            seen.insert(emoji)
        }
        combined = Array(combined.prefix(columns * rows))
        return stride(from: 0, to: combined.count, by: columns).map {
            Array(combined[$0..<min($0 + columns, combined.count)])
        }
    }

    /// Records a reaction picked from the context menu grid, so the next
    /// time the menu is shown (and the capsule/catalog) reflect the pick.
    static func record(_ emoji: String) {
        let char = Emoji(emoji)
        EmojiCategory.Persisted.frequent.addEmoji(char)
        EmojiCategory.Persisted.recent.addEmoji(char)
    }

    /// Renders an emoji as a fixed-size, non-template image for use as an
    /// `NSMenuItem.image` in a palette-style menu.
    static func image(for emoji: String, pointSize: CGFloat = 18) -> NSImage {
        let font = NSFont.systemFont(ofSize: pointSize)
        let attributed = NSAttributedString(string: emoji, attributes: [.font: font])
        let textSize = attributed.size()
        let side = ceil(max(textSize.width, textSize.height, pointSize))
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            )
            attributed.draw(at: origin)
            return true
        }
        image.isTemplate = false
        return image
    }
}
