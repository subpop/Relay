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

        let rendered = Self.renderPill(
            userId: userId, displayName: displayName,
            fontSize: font.pointSize, style: .compose
        )
        self.image = rendered.image
        self.bounds = CGRect(origin: .zero, size: rendered.size)
    }

    /// Creates a pill attachment for message rendering with a specific style.
    init(userId: String, displayName: String, font: NSFont, style: MentionPillStyle) {
        self.userId = userId
        self.displayName = displayName
        self.pillFontSize = font.pointSize
        super.init(data: nil, ofType: nil)
        self.attachmentCell = nil

        let rendered = Self.renderPill(
            userId: userId, displayName: displayName,
            fontSize: font.pointSize, style: style
        )
        self.image = rendered.image
        self.bounds = CGRect(origin: .zero, size: rendered.size)
    }

    /// Creates a pill attachment for a keyword highlight (no `@` prefix, no link).
    init(keyword: String, font: NSFont, style: MentionPillStyle) {
        self.userId = ""
        self.displayName = keyword
        self.pillFontSize = font.pointSize
        super.init(data: nil, ofType: nil)
        self.attachmentCell = nil

        let rendered = Self.renderPill(
            userId: "", displayName: keyword,
            fontSize: font.pointSize, style: style, showAtPrefix: false
        )
        self.image = rendered.image
        self.bounds = CGRect(origin: .zero, size: rendered.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PillTextAttachment does not support NSCoding")
    }

    // MARK: - Image Rendering

    /// Renders the ``MentionPillView`` to an `NSImage` at 2x resolution and
    /// returns it together with its natural point size.
    ///
    /// The pill text is rendered at `fontSize`, and the caller uses the returned
    /// natural size as the attachment bounds, so the bitmap is drawn 1:1 and is
    /// never scaled. The capsule therefore stays sharp and undistorted at any
    /// surrounding font size — including when the timeline text-zoom enlarges the
    /// message font. The explicit `scale` of 2 keeps pills crisp on Retina
    /// displays without relying on the window backing scale.
    private static func renderPill(
        userId: String, displayName: String, fontSize: CGFloat,
        style: MentionPillStyle, showAtPrefix: Bool = true
    ) -> (image: NSImage, size: CGSize) {
        MainActor.assumeIsolated {
            let tintColor = Color(stableColorFor: userId)
            let colorScheme: ColorScheme =
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .dark : .light
            let pillView = MentionPillView(
                displayName: displayName, tintColor: tintColor, style: style,
                showAtPrefix: showAtPrefix, fontSize: fontSize
            )
            .environment(\.colorScheme, colorScheme)
            let renderer = ImageRenderer(content: pillView)
            renderer.scale = 2

            if let image = renderer.nsImage {
                return (image, image.size)
            }
            // Rendering should never fail; fall back to the measured size so the
            // mention still reserves inline space.
            let size = MentionPillView.measureSize(
                displayName: displayName,
                font: NSFont.systemFont(ofSize: fontSize),
                showAtPrefix: showAtPrefix
            )
            return (NSImage(size: size), size)
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
        // Cap the attachment height to the font's line box (ascender − descender)
        // so the pill can never overhang the line it sits on. Without the cap the
        // padded pill (~18pt) is taller than the ~15.8pt line box, so a pill on
        // the first line overhangs the ascender and its top is clipped by the
        // bubble; every pill also reads as vertically tight. Centering the capped
        // height on the font midline places the pill exactly within
        // [descender, ascender].
        let lineHeight = font.ascender - font.descender
        let paddedHeight = min(pillSize.height + verticalPadding, lineHeight)
        let midline = (font.ascender + font.descender) / 2
        let y = midline - paddedHeight / 2
        return CGRect(
            origin: CGPoint(x: 0, y: y),
            size: CGSize(width: pillSize.width, height: paddedHeight)
        )
    }
}
