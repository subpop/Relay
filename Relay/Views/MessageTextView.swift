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

// MARK: - MessageTextContent (NSTextView subclass)

/// A read-only `NSTextView` subclass for rendering rich message text.
///
/// Provides native link hover behaviour (pointing-hand cursor and underline on
/// hover) and text selection. Designed to be extended for Matrix-specific
/// features such as mention pills, spoiler reveals, and custom emoji.
final class MessageTextContent: NSTextView {

    /// When `true`, `setFrameSize` will not update the text container's width.
    /// This prevents a feedback loop where SwiftUI's layout → `setFrameSize` →
    /// re-layout → smaller `sizeThatFits` → smaller frame → repeat.
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
                textStorage?.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
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

// MARK: - MessageTextView (NSViewRepresentable)

/// SwiftUI wrapper around ``MessageTextContent`` for rendering rich message
/// text with proper link hover behaviour, text selection, and layout sizing.
struct MessageTextView: NSViewRepresentable {
    let attributedString: AttributedString?
    let resolvedAttributedString: NSAttributedString?
    let isOutgoing: Bool

    /// Called when the user clicks a `matrix.to` user mention link, with the Matrix user ID.
    var onUserTap: ((String) -> Void)?

    /// Called when the user clicks a `matrix.to` room link, with the room ID or alias.
    var onRoomTap: ((String) -> Void)?

    /// Creates a ``MessageTextView`` from a SwiftUI `AttributedString` (Markdown path).
    init(
        attributedString: AttributedString,
        isOutgoing: Bool,
        onUserTap: ((String) -> Void)? = nil,
        onRoomTap: ((String) -> Void)? = nil
    ) {
        self.attributedString = attributedString
        self.resolvedAttributedString = nil
        self.isOutgoing = isOutgoing
        self.onUserTap = onUserTap
        self.onRoomTap = onRoomTap
    }

    /// Creates a ``MessageTextView`` from a pre-resolved `NSAttributedString` (HTML path).
    init(
        resolved: NSAttributedString,
        isOutgoing: Bool,
        onUserTap: ((String) -> Void)? = nil,
        onRoomTap: ((String) -> Void)? = nil
    ) {
        self.attributedString = nil
        self.resolvedAttributedString = resolved
        self.isOutgoing = isOutgoing
        self.onUserTap = onUserTap
        self.onRoomTap = onRoomTap
    }

    private var foregroundColor: NSColor {
        isOutgoing ? .white : .labelColor
    }

    private var linkColor: NSColor {
        isOutgoing ? NSColor.white.withAlphaComponent(0.9) : .controlAccentColor
    }

    func makeNSView(context: Context) -> MessageTextContent {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let view = MessageTextContent(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isAutomaticLinkDetectionEnabled = false
        view.setContentHuggingPriority(.required, for: .vertical)
        view.onUserTap = onUserTap
        view.onRoomTap = onRoomTap
        return view
    }

    func updateNSView(_ view: MessageTextContent, context: Context) {
        view.resetHoverState()
        view.onUserTap = onUserTap
        view.onRoomTap = onRoomTap
        let resolved: NSAttributedString
        if let preResolved = resolvedAttributedString {
            // HTML path: apply foreground/link color overrides to the pre-resolved string.
            resolved = Self.applyColorOverrides(
                preResolved,
                foreground: foregroundColor,
                linkColor: linkColor
            )
        } else if let attrString = attributedString {
            // Markdown path: resolve InlinePresentationIntent attributes.
            resolved = Self.resolve(
                attrString,
                foreground: foregroundColor,
                linkColor: linkColor
            )
        } else {
            resolved = NSAttributedString()
        }
        view.linkTextAttributes = [.foregroundColor: linkColor]
        view.textStorage?.setAttributedString(resolved)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: MessageTextContent, context: Context
    ) -> CGSize? {
        guard let container = nsView.textContainer,
              let lm = nsView.layoutManager,
              (nsView.textStorage?.length ?? 0) > 0
        else { return .zero }

        // Prevent setFrameSize from constraining the container while we measure.
        nsView.suppressContainerSync = true
        defer { nsView.suppressContainerSync = false }

        // Natural layout (unconstrained) to find the intrinsic text width.
        container.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        lm.ensureLayout(for: container)
        var naturalWidth: CGFloat = 0
        let storage = nsView.textStorage!
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: container)) {
            _, usedRect, _, glyphRange, _ in
            // Use maxX (origin.x + width) so that paragraph indents
            // (firstLineHeadIndent, headIndent) are included in the measurement.
            var lineWidth = usedRect.maxX
            // If this line's paragraph has a negative tailIndent, that space is
            // "reserved" on the trailing edge. Add it back so the bubble sizes
            // wide enough to avoid unnecessary wrapping.
            let charIndex = lm.characterIndexForGlyph(at: glyphRange.location)
            if charIndex < storage.length,
               let ps = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil)
                    as? NSParagraphStyle,
               ps.tailIndent < 0 {
                lineWidth -= ps.tailIndent // tailIndent is negative, so this adds
            }
            naturalWidth = max(naturalWidth, lineWidth)
        }
        let naturalHeight = lm.usedRect(for: container).height
        let tightWidth = ceil(naturalWidth)

        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }

        // Text fits within the proposed width without extra wrapping — hug it.
        guard let pw = proposedWidth, tightWidth > pw else {
            return CGSize(width: tightWidth, height: ceil(naturalHeight))
        }

        // Text must wrap to fit the proposed width. Use the full proposed width
        // so SwiftUI doesn't re-propose a narrower value (feedback loop).
        container.containerSize = NSSize(width: pw, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        let constrainedHeight = lm.usedRect(for: container).height

        return CGSize(width: pw, height: ceil(constrainedHeight))
    }

    // MARK: - Attribute Resolution

    /// Converts a SwiftUI `AttributedString` (with `InlinePresentationIntent`
    /// attributes from the markdown parser) into an `NSAttributedString` with
    /// resolved AppKit font/color attributes that `NSTextView` can render.
    static func resolve(
        _ source: AttributedString,
        foreground: NSColor,
        linkColor: NSColor
    ) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(source))
        let fullRange = NSRange(location: 0, length: result.length)
        let keys = NSAttributedString.Key.self

        result.addAttribute(keys.foregroundColor, value: foreground, range: fullRange)

        result.enumerateAttribute(keys.font, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                result.addAttribute(keys.font, value: baseFont, range: range)
            }
        }

        result.enumerateAttribute(keys.inlinePresentationIntent, in: fullRange, options: []) {
            value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)

            if intent.contains(.code) {
                let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                result.addAttribute(keys.font, value: mono, range: range)
                result.addAttribute(
                    keys.backgroundColor,
                    value: NSColor.gray.withAlphaComponent(0.12),
                    range: range
                )
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let desc = baseFont.fontDescriptor.withSymbolicTraits(traits)
                    let font = NSFont(descriptor: desc, size: baseFont.pointSize) ?? baseFont
                    result.addAttribute(keys.font, value: font, range: range)
                }
            }

            if intent.contains(.strikethrough) {
                result.addAttribute(
                    keys.strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }

        result.enumerateAttribute(keys.link, in: fullRange, options: []) { value, range, _ in
            if value != nil {
                result.addAttribute(keys.foregroundColor, value: linkColor, range: range)
            }
        }

            return result
    }

    /// Applies foreground and link color overrides to a pre-resolved `NSAttributedString`
    /// from the HTML parser, respecting any existing custom colors (e.g. `data-mx-color`).
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
        let mutedForeground = foreground.withAlphaComponent(0.55)
        // Subtle color for the "│" bar character.
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

        return result
    }
}

// MARK: - Previews

private func previewParse(_ raw: String) -> AttributedString {
    var result: AttributedString
    if let md = try? AttributedString(
        markdown: raw,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
        result = md
    } else {
        result = AttributedString(raw)
    }

    let plain = String(result.characters)
    guard let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    ) else { return result }

    for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
        guard let urlRange = Range(match.range, in: plain),
              let attrRange = Range(urlRange, in: result) else { continue }
        if result[attrRange].link == nil {
            result[attrRange].link = match.url
        }
    }
    return result
}

private struct BubblePreview: View {
    let text: String
    let isOutgoing: Bool

    var body: some View {
        MessageTextView(
            attributedString: previewParse(text),
            isOutgoing: isOutgoing
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct HTMLBubblePreview: View {
    let html: String
    let isOutgoing: Bool

    var body: some View {
        Group {
            if let resolved = MatrixHTMLParser.parse(html) {
                MessageTextView(resolved: resolved, isOutgoing: isOutgoing)
            } else {
                Text("Parse error")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

#Preview("Plain Text") {
    VStack(alignment: .leading, spacing: 12) {
        BubblePreview(text: "Yeah", isOutgoing: false)
        BubblePreview(text: "Oh, per room..", isOutgoing: true)
        BubblePreview(
            text: "I think it's the same across the board. Some rooms just limit posts and block images",
            isOutgoing: false
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Links") {
    VStack(alignment: .leading, spacing: 12) {
        BubblePreview(
            text: "Check out https://matrix.org for more info",
            isOutgoing: false
        )
        BubblePreview(
            text: "https://youtube.com/shorts/SDzKgqU35Eo\nWow these Neo ads are cute",
            isOutgoing: false
        )
        BubblePreview(
            text: "I sent you the link https://example.com/path already",
            isOutgoing: true
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Markdown Formatting") {
    VStack(alignment: .leading, spacing: 12) {
        BubblePreview(text: "This is **bold** text", isOutgoing: false)
        BubblePreview(text: "This is *italic* text", isOutgoing: false)
        BubblePreview(text: "This has `inline code` in it", isOutgoing: false)
        BubblePreview(text: "This is ~~strikethrough~~ text", isOutgoing: false)
        BubblePreview(
            text: "**Bold**, *italic*, `code`, and ~~struck~~ all at once",
            isOutgoing: false
        )
        BubblePreview(
            text: "Outgoing with **bold** and a link https://example.com",
            isOutgoing: true
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("HTML Inline Formatting") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HTMLBubblePreview(
                html: "This is <b>bold</b> and <strong>strong</strong> text",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "This is <i>italic</i> and <em>emphasized</em> text",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "This is <u>underlined</u> text",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "This is <s>strikethrough</s> and <del>deleted</del> text",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "Here is <code>inline code</code> in a sentence",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "Water is H<sub>2</sub>O and E=mc<sup>2</sup>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "Check out <a href=\"https://matrix.org\">Matrix</a> for more info",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<b>Bold</b>, <i>italic</i>, <code>code</code>, and <s>struck</s> all at once",
                isOutgoing: true
            )
            HTMLBubblePreview(
                html: "Text with <span data-mx-color=\"#ff0000\">red</span> and <span data-mx-color=\"#00aa00\">green</span> colors",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "This has a <span data-mx-spoiler>secret spoiler</span> hidden",
                isOutgoing: false
            )
        }
        .padding()
        .frame(width: 500)
    }
}

#Preview("HTML Block Elements") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HTMLBubblePreview(
                html: "<h1>Heading 1</h1><p>Paragraph after heading</p>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<h3>Heading 3</h3><p>Some text here</p>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<blockquote>This is a blockquote</blockquote><p>And normal text after</p>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<blockquote>This is a longer blockquote that should wrap to multiple lines to test trailing edge alignment</blockquote>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<blockquote>Outgoing blockquote text here</blockquote><p>My reply</p>",
                isOutgoing: true
            )
            HTMLBubblePreview(
                html: "<pre><code>func hello() {\n    print(\"Hello, world!\")\n}</code></pre>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<p>Line above</p><hr><p>Line below</p>",
                isOutgoing: false
            )
        }
        .padding()
        .frame(width: 500)
    }
}

#Preview("HTML Lists") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HTMLBubblePreview(
                html: "<ul><li>First item</li><li>Second item</li><li>Third item</li></ul>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<ol><li>Step one</li><li>Step two</li><li>Step three</li></ol>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<ol start=\"5\"><li>Item five</li><li>Item six</li><li>Item seven</li></ol>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<ul><li>Outer item<ul><li>Nested item 1</li><li>Nested item 2</li></ul></li><li>Back to outer</li></ul>",
                isOutgoing: false
            )
        }
        .padding()
        .frame(width: 500)
    }
}

#Preview("HTML Mixed Content") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HTMLBubblePreview(
                html: """
                <p>Here is a <b>complex</b> message with <i>mixed</i> content:</p>
                <blockquote>Someone said something <em>important</em></blockquote>
                <p>And then a list:</p>
                <ol><li>First</li><li>Second with <code>code</code></li></ol>
                <p>Followed by a <a href="https://example.com">link</a>.</p>
                """,
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: """
                <mx-reply><blockquote>Original message</blockquote></mx-reply>
                <p>This reply should have the mx-reply stripped</p>
                """,
                isOutgoing: true
            )
        }
        .padding()
        .frame(width: 500)
    }
}

