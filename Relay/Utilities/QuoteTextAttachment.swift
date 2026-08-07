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

// MARK: - QuoteTextAttachmentViewProvider

/// Provides a live SwiftUI ``QuoteIconView`` for inline rendering of the
/// blockquote icon in TextKit 2 text layouts.
///
/// This provider hosts the SwiftUI view directly in the text layout via
/// `NSHostingView`, so the icon adapts automatically to appearance changes,
/// accessibility settings, and Retina displays without manual scaling.
nonisolated final class QuoteTextAttachmentViewProvider: NSTextAttachmentViewProvider {

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
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? QuoteTextAttachment else { return }

            let colorScheme: ColorScheme =
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .dark : .light

            let quoteView = QuoteIconView(tint: attachment.tint)
                .frame(width: attachment.bounds.width, height: attachment.bounds.height)
                .environment(\.colorScheme, colorScheme)

            let hostingView = NSHostingView(rootView: quoteView)
            hostingView.sizingOptions = .intrinsicContentSize
            provider.view = hostingView
        }
    }
}

// MARK: - QuoteTextAttachment

/// An `NSTextAttachment` subclass that renders the leading quote icon for a
/// `<blockquote>`.
///
/// ``MatrixHTMLParser`` inserts a `\u{FFFC}` placeholder marked with
/// ``NSAttributedString/Key/blockquoteMarker`` at each blockquote start and
/// uses ``indentWidth(for:)`` to indent quoted content past the icon. At
/// render time ``MessageTextView/applyColorOverrides(_:foreground:linkColor:)``
/// replaces the placeholder with a ``QuoteTextAttachment``, so the icon can be
/// tinted to match the message bubble's foreground.
///
/// In TextKit 2 contexts the icon renders as a live SwiftUI ``QuoteIconView``
/// via ``QuoteTextAttachmentViewProvider``. A bitmap snapshot is kept on
/// ``image`` as a fallback for contexts where the view provider is not invoked
/// (e.g. offscreen measurement stacks, copy/paste).
nonisolated final class QuoteTextAttachment: NSTextAttachment, @unchecked Sendable {

    // MARK: - Sizing

    /// The SF Symbol used for the leading quote glyph.
    static let symbolName = "quote.opening"

    /// The icon is rendered at this multiple of the base font size, then capped
    /// to the line box so it never overhangs the line (see ``bounds(for:)``).
    static let scale: CGFloat = 1.6

    /// The paragraph head indent (and mirrored tail indent) applied to quoted
    /// content: the icon width plus the width of the space that follows it.
    static func indentWidth(for baseFont: NSFont) -> CGFloat {
        let spaceWidth = (" " as NSString)
            .size(withAttributes: [.font: baseFont]).width
        return bounds(for: baseFont).width + spaceWidth
    }

    /// The icon bounds within a text line. The height is capped to the font's
    /// line box (ascender − descender) and vertically centered on the font
    /// midline, mirroring ``PillTextAttachment``'s sizing so the icon never
    /// overhangs the line or gets clipped by the bubble.
    static func bounds(for baseFont: NSFont) -> CGRect {
        let symbolSize = symbolSize(for: baseFont)
        let lineHeight = baseFont.ascender - baseFont.descender
        let height = min(symbolSize.height, lineHeight)
        let width = symbolSize.width * (height / max(symbolSize.height, 0.001))
        let midline = (baseFont.ascender + baseFont.descender) / 2
        let y = midline - height / 2
        return CGRect(x: 0, y: y, width: width, height: height)
    }

    private static func symbolSize(for baseFont: NSFont) -> CGSize {
        let config = NSImage.SymbolConfiguration(
            pointSize: baseFont.pointSize * scale, weight: .medium
        )
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.size ?? .zero
    }

    // MARK: - State

    /// The point size of the surrounding message text, used to size the icon.
    /// Stored as a plain `CGFloat` to avoid `Sendable` issues with `NSFont`.
    let fontSize: CGFloat

    /// The tint applied to the quote glyph, derived from the message bubble's
    /// foreground color at render time.
    let tint: Color

    /// Creates a quote icon attachment sized for `fontSize` and tinted to `tint`.
    init(fontSize: CGFloat, tint: Color) {
        self.fontSize = fontSize
        self.tint = tint
        super.init(data: nil, ofType: nil)
        self.attachmentCell = nil

        let font = NSFont.systemFont(ofSize: fontSize)
        let bounds = MainActor.assumeIsolated { Self.bounds(for: font) }
        self.bounds = bounds
        self.image = Self.renderFallback(tint: tint, bounds: bounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("QuoteTextAttachment does not support NSCoding")
    }

    // MARK: - View Provider

    override var usesTextAttachmentView: Bool { true }

    @preconcurrency
    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        QuoteTextAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }

    // MARK: - Image Fallback

    /// Renders the ``QuoteIconView`` to an `NSImage` at 2x resolution.
    /// Used as a fallback for contexts where the view provider is not invoked
    /// (e.g. offscreen measurement stacks, copy/paste).
    private static func renderFallback(tint: Color, bounds: CGRect) -> NSImage? {
        MainActor.assumeIsolated {
            let quoteView = QuoteIconView(tint: tint)
                .frame(width: bounds.width, height: bounds.height)
            let renderer = ImageRenderer(content: quoteView)
            renderer.scale = 2
            return renderer.nsImage
        }
    }
}

// MARK: - QuoteIconView

/// A monochrome quote glyph tinted to match the surrounding message bubble.
///
/// ``QuoteIconView`` is displayed inline by ``QuoteTextAttachment``. In
/// TextKit 2 contexts it is hosted live via ``QuoteTextAttachmentViewProvider``;
/// a bitmap snapshot is kept as a fallback. Callers size it with a fixed frame
/// matching the attachment bounds, so the glyph scales to fit the line box.
struct QuoteIconView: View {
    /// The tint applied to the glyph, derived from the bubble's foreground.
    var tint: Color = .primary

    var body: some View {
        Image(systemName: QuoteTextAttachment.symbolName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .font(.system(size: 100, weight: .medium))
            .foregroundStyle(tint)
    }
}

#Preview("Incoming Bubble") {
    HStack(alignment: .top) {
        QuoteIconView(tint: .primary)
            .frame(width: 23, height: 15)
        Text("Here is a longer quoted message that wraps across a few lines so you can see how the quote icon sits alongside the indented, multi-line quoted content.")
    }
    .padding(10)
    .background(Color(.unemphasizedSelectedContentBackgroundColor), in: .rect(cornerRadius: 12))
    .padding()
}

#Preview("Outgoing Bubble") {
    HStack(alignment: .top) {
        QuoteIconView(tint: .white)
            .frame(width: 23, height: 15)
        Text("Here is a longer quoted message that wraps across a few lines so you can see how the quote icon sits alongside the indented, multi-line quoted content.")
    }
    .padding(10)
    .background(Color.accentColor, in: .rect(cornerRadius: 12))
    .padding()
}
