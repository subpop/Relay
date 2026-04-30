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

    /// Creates a pill attachment for the compose bar (stable color tint, no border).
    init(userId: String, displayName: String, font: NSFont) {
        self.userId = userId
        self.displayName = displayName
        self.pillFontSize = font.pointSize
        super.init(data: nil, ofType: nil)
        self.attachmentCell = nil

        let fontSize = font.pointSize
        let pillSize = MainActor.assumeIsolated {
            MentionPillView.measureSize(
                displayName: displayName,
                font: NSFont.systemFont(ofSize: fontSize)
            )
        }
        self.image = Self.renderPillImage(
            userId: userId, displayName: displayName, size: pillSize, style: .compose
        )
        self.bounds = CGRect(origin: .zero, size: pillSize)
    }

    /// Creates a pill attachment for message rendering with a specific style.
    init(userId: String, displayName: String, font: NSFont, style: MentionPillStyle) {
        self.userId = userId
        self.displayName = displayName
        self.pillFontSize = font.pointSize
        super.init(data: nil, ofType: nil)
        self.attachmentCell = nil

        let fontSize = font.pointSize
        let pillSize = MainActor.assumeIsolated {
            MentionPillView.measureSize(
                displayName: displayName,
                font: NSFont.systemFont(ofSize: fontSize)
            )
        }
        self.image = Self.renderPillImage(
            userId: userId, displayName: displayName, size: pillSize, style: style
        )
        self.bounds = CGRect(origin: .zero, size: pillSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PillTextAttachment does not support NSCoding")
    }

    // MARK: - Image Rendering

    /// Renders the ``MentionPillView`` to a static `NSImage` at 2x resolution.
    ///
    /// Uses SwiftUI's `ImageRenderer` with an explicit scale of 2 so that pills
    /// look sharp on Retina displays without relying on window backing scale.
    /// The resulting `NSImage` has its logical size set to the 1x point size so
    /// TextKit positions it correctly.
    private static func renderPillImage(
        userId: String, displayName: String, size: CGSize, style: MentionPillStyle
    ) -> NSImage {
        MainActor.assumeIsolated {
            let tintColor = StableNameColor.color(for: userId)
            let colorScheme: ColorScheme =
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .dark : .light
            let pillView = MentionPillView(
                displayName: displayName, tintColor: tintColor, style: style
            )
            .environment(\.colorScheme, colorScheme)
            let renderer = ImageRenderer(content: pillView)
            renderer.scale = 2

            guard let cgImage = renderer.cgImage else {
                return NSImage(size: size)
            }
            return NSImage(cgImage: cgImage, size: size)
        }
    }

    // MARK: - Attachment Bounds

    /// Extra vertical padding (top + bottom) added to the pill's natural height
    /// so that the line fragment expands and the image draws at full size
    /// without being compressed.
    private static let verticalPadding: CGFloat = 2

    /// TextKit 2 attachment bounds. Called by `NSTextLayoutManager` during layout.
    @preconcurrency
    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        Self.paddedBounds(pillSize: bounds.size, fontSize: pillFontSize)
    }

    /// TextKit 1 attachment bounds (fallback).
    @preconcurrency
    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        Self.paddedBounds(pillSize: bounds.size, fontSize: pillFontSize)
    }

    /// Returns attachment bounds with vertical padding so the pill image draws
    /// at its natural size. The y origin centers the padded rect on the font's
    /// visual midline (midpoint between ascender and descender).
    private static func paddedBounds(pillSize: CGSize, fontSize: CGFloat) -> CGRect {
        let font = NSFont.systemFont(ofSize: fontSize)
        let paddedHeight = pillSize.height + verticalPadding
        let midline = (font.ascender + font.descender) / 2
        let y = midline - paddedHeight / 2
        return CGRect(
            origin: CGPoint(x: 0, y: y),
            size: CGSize(width: pillSize.width, height: paddedHeight)
        )
    }
}
