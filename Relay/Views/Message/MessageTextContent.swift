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

// MARK: - MessageTextContent (NSTextView subclass)

/// A read-only `NSTextView` subclass for rendering rich message text.
///
/// Provides native link hover behaviour (pointing-hand cursor and underline on
/// hover) and text selection. Designed to be extended for Matrix-specific
/// features such as mention pills and `matrix.to` links.
final class MessageTextContent: NSTextView {

    /// When `true`, `setFrameSize` will not update the text container's width.
    /// This prevents a feedback loop where SwiftUI's layout -> `setFrameSize` ->
    /// re-layout -> smaller `sizeThatFits` -> smaller frame -> repeat.
    var suppressContainerSync = false

    /// Called when the user clicks a `matrix.to` user mention link, with the Matrix user ID.
    var onUserTap: ((String) -> Void)?

    /// Called when the user clicks a `matrix.to` room link, with the room ID or alias.
    var onRoomTap: ((String) -> Void)?

    // MARK: - Link Click Interception

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL, let uri = MatrixURI(url: url) {
            switch uri {
            case .user(let id):
                onUserTap?(id)
            case .room(let alias, _):
                onRoomTap?(alias)
            case .roomId(let id, _):
                onRoomTap?(id)
            case .event(let roomId, _, _):
                onRoomTap?(roomId)
            }
            return
        }
        super.clicked(onLink: link, at: charIndex)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // swiftlint:disable:next identifier_name
        if !suppressContainerSync, let tc = textContainer, newSize.width > 0 {
            tc.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: - Hover State

    private var hoveredLinkRange: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let range = linkRange(at: point) {
            if hoveredLinkRange != range {
                clearHoverUnderline()
                // Skip hover underline for mention pill attachments —
                // they render as inline images and shouldn't be underlined.
                let isPillAttachment = textStorage?.attribute(
                    .attachment, at: range.location, effectiveRange: nil
                ) is PillTextAttachment
                if !isPillAttachment {
                    textStorage?.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
                hoveredLinkRange = range
            }
            NSCursor.pointingHand.set()
        } else {
            if hoveredLinkRange != nil { clearHoverUnderline() }
            super.mouseMoved(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        clearHoverUnderline()
        super.mouseExited(with: event)
    }

    func resetHoverState() {
        clearHoverUnderline()
    }

    // MARK: - Private Helpers

    private func clearHoverUnderline() {
        if let range = hoveredLinkRange, let textStorage,
           range.upperBound <= textStorage.length {
            textStorage.removeAttribute(.underlineStyle, range: range)
        }
        hoveredLinkRange = nil
    }

    private func linkRange(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)

        let glyphIndex = layoutManager.glyphIndex(for: local, in: textContainer)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(local) else { return nil }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length else { return nil }

        var effectiveRange = NSRange()
        guard textStorage.attribute(.link, at: charIndex, effectiveRange: &effectiveRange) != nil
        else { return nil }
        return effectiveRange
    }
}
