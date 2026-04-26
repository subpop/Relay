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
import SwiftUI

// MARK: - Custom Attribute Keys

extension NSAttributedString.Key {
    /// The Matrix user ID stored on a mention pill attachment character.
    static let mentionUserID = NSAttributedString.Key("relay.mentionUserID")

    /// The display name stored on a mention pill attachment character.
    static let mentionDisplayName = NSAttributedString.Key("relay.mentionDisplayName")
}

// MARK: - PillTextAttachment

/// An `NSTextAttachment` subclass that represents an inline mention pill.
///
/// Each pill stores the mentioned user's ID and display name. The attachment
/// character (`\u{FFFC}`) is atomically deletable — deleting any part of it
/// removes the entire mention.
///
/// The pill is rendered as an `NSImage` at creation time by snapshotting a
/// SwiftUI ``MentionPillView`` via `NSHostingView`. This approach works with
/// both TextKit 1 and TextKit 2 on macOS (`NSTextAttachmentViewProvider` is
/// not supported by `NSTextView` on macOS despite existing in the API).
nonisolated final class PillTextAttachment: NSTextAttachment, @unchecked Sendable {

    /// The Matrix user ID for this mention (e.g. `@alice:matrix.org`).
    let userId: String

    /// The display name shown in the pill (e.g. `Alice Smith`).
    let displayName: String

    /// The font size of the surrounding text, used to size the pill correctly.
    /// Stored as a plain `CGFloat` to avoid `Sendable` issues with `NSFont`.
    let pillFontSize: CGFloat

    init(userId: String, displayName: String, font: NSFont) {
        self.userId = userId
        self.displayName = displayName
        self.pillFontSize = font.pointSize
        super.init(data: nil, ofType: nil)
        // On macOS, NSTextAttachment auto-creates an NSTextAttachmentCell.
        // Nil it out so we control rendering via the image property.
        self.attachmentCell = nil

        // Render the pill SwiftUI view to a static NSImage.
        let pillSize = MentionPillView.measureSize(
            displayName: displayName,
            font: NSFont.systemFont(ofSize: font.pointSize)
        )
        self.image = Self.renderPillImage(displayName: displayName, size: pillSize)
        self.bounds = CGRect(origin: .zero, size: pillSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PillTextAttachment does not support NSCoding")
    }

    // MARK: - Image Rendering

    /// Renders the ``MentionPillView`` to a static `NSImage` for inline display.
    private static func renderPillImage(displayName: String, size: CGSize) -> NSImage {
        MainActor.assumeIsolated {
            let pillView = MentionPillView(displayName: displayName)
            let hostingView = NSHostingView(rootView: pillView)
            let bounds = CGRect(origin: .zero, size: size)
            hostingView.frame = bounds

            // Force layout so the hosting view measures its SwiftUI content.
            hostingView.layoutSubtreeIfNeeded()

            guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
                return NSImage(size: size)
            }
            hostingView.cacheDisplay(in: bounds, to: bitmapRep)

            let image = NSImage(size: size)
            image.addRepresentation(bitmapRep)
            return image
        }
    }

    // MARK: - Attachment Bounds

    /// TextKit 2 attachment bounds. Called by `NSTextLayoutManager` during layout.
    @preconcurrency
    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let pillSize = bounds.size
        let font = NSFont.systemFont(ofSize: pillFontSize)
        // y is relative to the baseline. Place the pill so its vertical
        // center aligns with the midpoint between ascender and descender.
        let midline = (font.ascender + font.descender) / 2
        let y = midline - pillSize.height / 2
        return CGRect(origin: CGPoint(x: 0, y: y), size: pillSize)
    }

    /// TextKit 1 attachment bounds (fallback).
    @preconcurrency
    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let pillSize = bounds.size
        let font = NSFont.systemFont(ofSize: pillFontSize)
        let midline = (font.ascender + font.descender) / 2
        let y = midline - pillSize.height / 2
        return CGRect(origin: CGPoint(x: 0, y: y), size: pillSize)
    }
}
