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

// MARK: - MessageTextView (NSViewRepresentable)

/// SwiftUI wrapper around ``MessageTextContent`` for rendering rich message
/// text with proper link hover behaviour, text selection, and layout sizing.
///
/// Accepts a single `NSAttributedString` representing the parsed message body
/// (either from ``NSAttributedString/init(matrixHTML:)`` or
/// ``NSAttributedString/init(matrixMarkdown:)``). Color overrides for the
/// current bubble style are applied at render time.
struct MessageTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let isOutgoing: Bool

    /// Called when the user clicks a `matrix.to` user mention link, with the Matrix user ID.
    var onUserTap: ((String) -> Void)?

    /// Called when the user clicks a `matrix.to` room link, with the room ID or alias.
    var onRoomTap: ((String) -> Void)?

    private var foregroundColor: NSColor {
        isOutgoing ? .white : .labelColor
    }

    private var linkColor: NSColor {
        isOutgoing ? NSColor.white.withAlphaComponent(0.9) : .controlAccentColor
    }

    // MARK: - Coordinator

    /// Caches the last resolved `NSAttributedString` so that `updateNSView`
    /// can skip the expensive `applyColorOverrides()` conversion when the
    /// inputs have not changed. Without this, every SwiftUI layout pass
    /// re-runs attribute enumeration on the main thread, which beach-balls
    /// when many messages are visible.
    final class Coordinator {
        var lastAttributedString: NSAttributedString?
        var lastIsOutgoing: Bool?
        var cachedResolved: NSAttributedString?

        /// Cached result from `sizeThatFits` to avoid redundant
        /// `NSLayoutManager.ensureLayout` calls when SwiftUI re-measures
        /// with the same proposal and text content.
        var cachedSizeProposedWidth: CGFloat?
        var cachedSizeResult: CGSize?
        var cachedSizeTextLength: Int?
        var cachedSizeTextHash: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        view.clipsToBounds = false
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isAutomaticLinkDetectionEnabled = false
        view.setContentHuggingPriority(.required, for: .vertical)
        view.onUserTap = onUserTap
        view.onRoomTap = onRoomTap

        // Populate text immediately so sizeThatFits (which SwiftUI may
        // call before updateNSView) has content to measure. Without this,
        // the text storage is empty and sizeThatFits returns .zero,
        // causing the hosting controller to compute incorrect row heights.
        let coordinator = context.coordinator
        let resolved = Self.applyColorOverrides(
            attributedString, foreground: foregroundColor, linkColor: linkColor,
            isOutgoing: isOutgoing
        )
        coordinator.lastAttributedString = attributedString
        coordinator.lastIsOutgoing = isOutgoing
        coordinator.cachedResolved = resolved
        view.linkTextAttributes = [.foregroundColor: linkColor]
        storage.setAttributedString(resolved)

        return view
    }

    func updateNSView(_ view: MessageTextContent, context: Context) {
        view.resetHoverState()
        view.onUserTap = onUserTap
        view.onRoomTap = onRoomTap

        let coordinator = context.coordinator

        // Check whether the inputs that affect the resolved string have changed.
        let inputsChanged: Bool = {
            if coordinator.cachedResolved == nil { return true }
            if coordinator.lastIsOutgoing != isOutgoing { return true }
            return attributedString !== coordinator.lastAttributedString
        }()

        if inputsChanged {
            let resolved = Self.applyColorOverrides(
                attributedString,
                foreground: foregroundColor,
                linkColor: linkColor,
                isOutgoing: isOutgoing
            )
            coordinator.lastAttributedString = attributedString
            coordinator.lastIsOutgoing = isOutgoing
            coordinator.cachedResolved = resolved

            view.linkTextAttributes = [.foregroundColor: linkColor]
            view.textStorage?.setAttributedString(resolved)

            // Invalidate the size cache — the text content changed.
            coordinator.cachedSizeResult = nil
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: MessageTextContent, context: Context
    ) -> CGSize? {
        guard let container = nsView.textContainer,
              // swiftlint:disable:next identifier_name
              let lm = nsView.layoutManager,
              let textLength = nsView.textStorage?.length,
              textLength > 0
        else { return .zero }

        // Return the cached size if the proposal and text haven't changed.
        // Use the text storage hash (not just length) to detect recycled
        // cells where sizeThatFits is called before updateNSView replaces
        // the text content.
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let coordinator = context.coordinator
        let textHash = nsView.textStorage?.string.hashValue ?? 0
        if let cached = coordinator.cachedSizeResult,
           coordinator.cachedSizeTextLength == textLength,
           coordinator.cachedSizeTextHash == textHash,
           coordinator.cachedSizeProposedWidth == proposedWidth {
            return cached
        }

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
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: container)) { _, usedRect, _, glyphRange, _ in
            // Use maxX (origin.x + width) so that paragraph indents
            // (firstLineHeadIndent, headIndent) are included in the measurement.
            var lineWidth = usedRect.maxX
            // If this line's paragraph has a negative tailIndent, that space is
            // "reserved" on the trailing edge. Add it back so the bubble sizes
            // wide enough to avoid unnecessary wrapping.
            let charIndex = lm.characterIndexForGlyph(at: glyphRange.location)
            if charIndex < storage.length,
               // swiftlint:disable:next identifier_name
               let ps = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil)
                    as? NSParagraphStyle,
               ps.tailIndent < 0 {
                lineWidth -= ps.tailIndent // tailIndent is negative, so this adds
            }
            naturalWidth = max(naturalWidth, lineWidth)
        }
        let naturalHeight = lm.usedRect(for: container).height
        let tightWidth = ceil(naturalWidth)

        let result: CGSize

        // swiftlint:disable:next identifier_name
        if let pw = proposedWidth, pw > 0 {
            if tightWidth > pw {
                // Text must wrap to fit the proposed width.
                container.containerSize = NSSize(width: pw, height: CGFloat.greatestFiniteMagnitude)
                lm.ensureLayout(for: container)
                let constrainedHeight = lm.usedRect(for: container).height
                result = CGSize(width: pw, height: ceil(constrainedHeight))
            } else {
                // Text fits on fewer lines — hug the text width but never
                // exceed the proposed width. This ensures SwiftUI sets the
                // NSTextView frame within the bubble's clipping bounds.
                result = CGSize(width: tightWidth, height: ceil(naturalHeight))
            }
        } else {
            // No proposed width (ideal size query) — return natural size
            // but cap at the bubble max width so the frame doesn't extend
            // past the clipping boundary.
            let cappedWidth = min(tightWidth, 476) // 500 maxBubbleWidth - 24 bubblePadding
            if cappedWidth < tightWidth {
                container.containerSize = NSSize(width: cappedWidth, height: CGFloat.greatestFiniteMagnitude)
                lm.ensureLayout(for: container)
                let h = lm.usedRect(for: container).height
                result = CGSize(width: cappedWidth, height: ceil(h))
            } else {
                result = CGSize(width: tightWidth, height: ceil(naturalHeight))
            }
        }

        coordinator.cachedSizeProposedWidth = proposedWidth
        coordinator.cachedSizeResult = result
        coordinator.cachedSizeTextLength = textLength
        coordinator.cachedSizeTextHash = textHash

        return result
    }

}

// MARK: - Previews

private struct BubblePreview: View {
    let text: String
    let isOutgoing: Bool

    var body: some View {
        MessageTextView(
            attributedString: NSAttributedString(matrixMarkdown: text),
            isOutgoing: isOutgoing
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2))
        .clipShape(.rect(cornerRadius: 17))
    }
}

private struct HTMLBubblePreview: View {
    let html: String
    let isOutgoing: Bool

    var body: some View {
        Group {
            if let resolved = NSAttributedString(matrixHTML: html) {
                MessageTextView(attributedString: resolved, isOutgoing: isOutgoing)
            } else {
                Text("Parse error")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2))
        .clipShape(.rect(cornerRadius: 17))
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
                // swiftlint:disable:next line_length
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
                // swiftlint:disable:next line_length
                html: "<blockquote>This is a longer blockquote that should wrap to multiple lines to test trailing edge alignment</blockquote>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: "<blockquote><blockquote>This is a nested blockquote that should wrap to multiple lines to test trailing edge alignment</blockquote></blockquote>",
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
                // swiftlint:disable:next line_length
                html: "<ul><li>Outer item<ul><li>Nested item 1</li><li>Nested item 2</li></ul></li><li>Back to outer</li></ul>",
                isOutgoing: false
            )
        }
        .padding()
        .frame(width: 500)
    }
}

#Preview("HTML Nested Blockquotes") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HTMLBubblePreview(
                html: """
                <blockquote><blockquote><p>Original message</p></blockquote>\
                <p>First reply</p></blockquote>\
                <p>Second reply</p>
                """,
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: """
                <blockquote><blockquote><blockquote>\
                <p>Deep nested quote</p></blockquote>\
                <p>Middle reply</p></blockquote>\
                <p>Outer reply</p></blockquote>\
                <p>My response</p>
                """,
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: """
                <blockquote><blockquote><p>They said this</p></blockquote>\
                <p>And I replied with <b>emphasis</b></p></blockquote>\
                <p>Outgoing nested quote</p>
                """,
                isOutgoing: true
            )
            HTMLBubblePreview(
                // swiftlint:disable:next line_length
                html: "<p>Some context before the quote:</p><blockquote><p>This is the quoted text that spans multiple lines and should wrap nicely within the blockquote bar</p></blockquote><p>And here is the follow-up paragraph after the quote.</p>",
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: """
                <blockquote><blockquote>\
                <p>Alice: Has anyone tried the new SDK release?</p>\
                <p>It has some breaking changes.</p>\
                </blockquote>\
                <p>Bob: Yes, I migrated yesterday. The new async API is much cleaner.</p>\
                </blockquote>\
                <p>Carol: Thanks for the heads up, I'll update today.</p>
                """,
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: """
                <blockquote><blockquote><blockquote>\
                <p>How do I install it?</p>\
                </blockquote>\
                <p>Check the <a href="https://example.com">docs</a>, \
                it's under <code>Getting Started</code>.</p>\
                </blockquote>\
                <p>That worked, thanks! I also had to run:</p>\
                <pre><code>swift package update</code></pre>\
                </blockquote>\
                <p>Glad you got it sorted.</p>
                """,
                isOutgoing: false
            )
            HTMLBubblePreview(
                html: """
                <blockquote><blockquote>\
                <p>Are we still meeting at 3pm?</p>\
                </blockquote>\
                <p>Moved to 4pm, check the calendar.</p>\
                </blockquote>\
                <p>Got it, see you then!</p>
                """,
                isOutgoing: true
            )
            HTMLBubblePreview(
                html: """
                Per your email:
                <blockquote>
                <blockquote>
                On Tuesday, we are planning on releasing our newest product. We are planning a live stream announcement to talk about it.
                </blockquote>
                Which product is that?
                </blockquote>
                """,
                isOutgoing: true
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

#Preview("Mention Pills") {
    VStack(alignment: .leading, spacing: 12) {
        HTMLBubblePreview(
            html: """
            <p>Hey <a href="https://matrix.to/#/@alice:matrix.org">Alice</a>, \
            did you see the update?</p>
            """,
            isOutgoing: false
        )
        HTMLBubblePreview(
            html: """
            <p>Thanks <a href="https://matrix.to/#/@bob:example.com">Bob Smith</a>! \
            Let me check with <a href="https://matrix.to/#/@charlie:matrix.org">Charlie</a> too.</p>
            """,
            isOutgoing: true
        )
        BubblePreview(
            text: "Ping [@dave:matrix.org](https://matrix.to/#/@dave:matrix.org)",
            isOutgoing: false
        )
    }
    .padding()
    .frame(width: 500)
}
