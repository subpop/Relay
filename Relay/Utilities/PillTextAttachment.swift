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

// MARK: - Custom Attribute Keys

extension NSAttributedString.Key {
    /// The Matrix user ID stored on a mention pill attachment character.
    static let mentionUserID = NSAttributedString.Key("relay.mentionUserID")

    /// The display name stored on a mention pill attachment character.
    static let mentionDisplayName = NSAttributedString.Key("relay.mentionDisplayName")
}

// MARK: - PillTextAttachmentViewProvider

/// Provides a live ``PillAttachmentView`` for inline rendering of mention
/// pills in TextKit 2 text layouts.
nonisolated final class PillTextAttachmentViewProvider: NSTextAttachmentViewProvider {

    nonisolated override init(
        textAttachment: NSTextAttachment,
        parentView: NSView?,
        textLayoutManager: NSTextLayoutManager?,
        location: any NSTextLocation
    ) {
        super.init(
            textAttachment: textAttachment,
            parentView: parentView,
            textLayoutManager: textLayoutManager,
            location: location
        )
    }

    override func loadView() {
        // AppKit loads attachment views on the UI thread but its provider API
        // is preconcurrency.
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? PillTextAttachment else { return }
            provider.view = PillAttachmentView(
                displayName: attachment.displayName,
                userId: attachment.userId,
                style: attachment.style,
                prefixSigil: attachment.prefixSigil,
                fontSize: attachment.pillFontSize
            )
        }
    }
}

// MARK: - PillTextAttachment

/// An `NSTextAttachment` subclass that represents an inline mention pill.
///
/// Each pill stores the mentioned user's ID and display name. The attachment
/// character (`\u{FFFC}`) is atomically deletable — deleting any part of it
/// removes the entire mention.
///
/// The pill renders through ``PillTextAttachmentViewProvider`` as a live
/// ``PillAttachmentView`` wherever TextKit hosts attachment views. Some
/// contexts never host views — detached measurement stacks, copy/paste — and
/// on macOS 27.2 `NSTextView` itself falls back to the attachment-image path
/// even for view-backed attachments (Apple's own TextKit sample app exhibits
/// the same). Those contexts rasterize the live view on demand via
/// ``image(for:attributes:location:textContainer:)``, which AppKit re-invokes
/// on each display pass, so dynamic colors re-resolve per render.
nonisolated final class PillTextAttachment: NSTextAttachment, @unchecked Sendable {

    /// The Matrix user ID for this mention (e.g. `@alice:matrix.org`).
    let userId: String

    /// The display name shown in the pill (e.g. `Alice Smith`).
    let displayName: String

    /// The font size of the surrounding text, used to size the pill correctly.
    /// Stored as a plain `CGFloat` to avoid `Sendable` issues with `NSFont`.
    let pillFontSize: CGFloat

    /// The visual style of the pill (compose, message, highlight).
    let style: MentionPillStyle

    /// The sigil prepended to the display name — `@` for a user mention,
    /// `#` for a room mention. `nil` means no prefix.
    let prefixSigil: Character?

    /// Creates a pill attachment for the compose bar (stable color tint, no border).
    convenience init(userId: String, displayName: String, font: NSFont) {
        self.init(
            userId: userId,
            displayName: displayName,
            font: font,
            style: .compose,
            prefixSigil: "@"
        )
    }

    /// Creates a pill attachment for a keyword highlight (no prefix, no link).
    convenience init(keyword: String, font: NSFont, style: MentionPillStyle) {
        self.init(
            userId: "",
            displayName: keyword,
            font: font,
            style: style,
            prefixSigil: nil
        )
    }

    init(userId: String, displayName: String, font: NSFont, style: MentionPillStyle, prefixSigil: Character?) {
        let fontSize = font.pointSize
        self.userId = userId
        self.displayName = displayName
        self.pillFontSize = fontSize
        self.style = style
        self.prefixSigil = prefixSigil
        super.init(data: nil, ofType: nil)
        self.attachmentCell = nil

        // Measurement is MainActor-isolated (AppKit text APIs); the font is
        // reduced to a point size first so nothing non-Sendable crosses the
        // isolation boundary.
        let pillSize = MainActor.assumeIsolated {
            PillAttachmentView.measureSize(
                displayName: displayName,
                font: NSFont.systemFont(ofSize: fontSize),
                prefixSigil: prefixSigil
            )
        }
        self.bounds = Self.paddedBounds(pillSize: pillSize, fontSize: fontSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PillTextAttachment does not support NSCoding")
    }

    // MARK: - Live View

    override var usesTextAttachmentView: Bool { true }

    @preconcurrency
    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        PillTextAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }

    /// Rasterizes the live ``PillAttachmentView`` for contexts where no
    /// attachment view is installed: detached measurement stacks, copy/paste,
    /// and `NSTextView`'s attachment-image path on macOS 27.2 (see the class
    /// documentation). Rasterizing the live view — rather than rendering a
    /// separate bitmap — guarantees this output is pixel-identical to the
    /// hosted pill wherever TextKit does install the view.
    @preconcurrency
    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any] = [:],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
            let provider = viewProvider(for: nil, location: location, textContainer: textContainer)
        else { return nil }

        nonisolated(unsafe) let uiProvider = provider
        return MainActor.assumeIsolated {
            uiProvider.loadView()
            guard let view = uiProvider.view else { return nil }
            view.setFrameSize(bounds.size)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()

            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(bitmap)
            return image
        }
    }

    // MARK: - Attachment Bounds

    /// Extra vertical padding (top + bottom) added to the pill's natural height
    /// so that the line fragment expands and the pill draws at full size
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

    /// Returns attachment bounds with vertical padding so the pill draws
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
