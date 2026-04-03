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
import SwiftSoup

// MARK: - MatrixHTMLParser

/// Parses Matrix `org.matrix.custom.html` formatted message bodies into
/// `NSAttributedString` values suitable for rendering in ``MessageTextView``.
///
/// Supports the subset of HTML tags recommended by the
/// [Matrix Client-Server API specification](https://spec.matrix.org/latest/client-server-api/#mroommessage-msgtypes):
///
/// **Inline:** `b`, `strong`, `i`, `em`, `u`, `s`, `del`, `code`, `a`, `span`,
///             `sub`, `sup`, `br`, `font` (deprecated)
///
/// **Block:** `p`, `div`, `blockquote`, `pre`, `h1`–`h6`, `hr`, `ul`, `ol`, `li`
///
/// Tags outside this set are stripped (their text content is preserved).
/// Attributes are sanitized per the spec's allow-list.
enum MatrixHTMLParser {

    // MARK: - Public API

    /// Parses a Matrix HTML string into an `NSAttributedString`.
    ///
    /// - Parameter html: The raw HTML string from a `formatted_body` field.
    /// - Returns: An `NSAttributedString` with resolved AppKit attributes, or `nil`
    ///   if parsing fails entirely.
    static func parse(_ html: String) -> NSAttributedString? {
        guard let document = try? SwiftSoup.parseBodyFragment(html) else { return nil }
        guard let body = document.body() else { return nil }

        // Strip <mx-reply> blocks per spec (Changed in v1.13).
        _ = try? body.select("mx-reply").remove()

        let result = NSMutableAttributedString()
        let context = RenderContext()
        renderChildren(of: body, into: result, context: context)

        // Trim trailing newlines that block elements leave behind.
        trimTrailingNewlines(result)

        return result
    }

    // MARK: - Allowed Tags

    /// The set of tags we actively render. Everything else is stripped (text preserved).
    private static let allowedTags: Set<String> = [
        // Inline
        "b", "strong", "i", "em", "u", "s", "del", "code", "a", "span", "sub", "sup", "br",
        "font", // deprecated but still supported for reading
        // Block
        "p", "div", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "ul", "ol", "li",
    ]

    /// Tags that introduce block-level breaks.
    private static let blockTags: Set<String> = [
        "p", "div", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "ul", "ol", "li",
    ]

    /// Allowed URL schemes for `<a href>` links (per spec).
    private static let allowedLinkSchemes: Set<String> = [
        "https", "http", "ftp", "mailto", "magnet",
    ]

    // MARK: - Render Context

    /// Mutable state carried through the recursive tree walk.
    private final class RenderContext {
        /// Current font traits inherited from ancestor elements.
        var bold = false
        var italic = false
        var isCode = false
        var isPreformatted = false

        /// Decorations
        var underline = false
        var strikethrough = false

        /// Superscript / subscript nesting depth (positive = super, negative = sub).
        var baselineShift: Int = 0

        /// Current foreground color override (from `data-mx-color` or `color` attr).
        var foregroundColor: NSColor?

        /// Current background color override (from `data-mx-bg-color`).
        var backgroundColor: NSColor?

        /// Link URL to apply (when inside an `<a>` tag).
        var linkURL: URL?

        /// Blockquote nesting depth.
        var blockquoteDepth: Int = 0

        /// List context stack: each entry is (ordered: Bool, counter: Int, startValue: Int).
        var listStack: [(ordered: Bool, counter: Int, start: Int)] = []

        /// Whether a spoiler is active (data-mx-spoiler).
        var isSpoiler = false

        /// When `true`, the next call to `ensureBlockBreak` is skipped (and the
        /// flag is reset). Used after the blockquote bar so the first child
        /// `<p>` doesn't inject a newline between the bar and its text.
        var suppressNextBlockBreak = false

        /// Creates a snapshot of the current context for push/pop.
        ///
        /// Note: `listStack` and `blockquoteDepth` are intentionally excluded from
        /// snapshot/restore because they are managed structurally by the `<ul>`/`<ol>`
        /// and `<blockquote>` handlers, and list item counters must persist across
        /// sibling `<li>` elements.
        func snapshot() -> Snapshot {
            Snapshot(
                bold: bold, italic: italic, isCode: isCode, isPreformatted: isPreformatted,
                underline: underline, strikethrough: strikethrough,
                baselineShift: baselineShift,
                foregroundColor: foregroundColor, backgroundColor: backgroundColor,
                linkURL: linkURL, isSpoiler: isSpoiler
            )
        }

        func restore(_ s: Snapshot) {
            bold = s.bold; italic = s.italic; isCode = s.isCode; isPreformatted = s.isPreformatted
            underline = s.underline; strikethrough = s.strikethrough
            baselineShift = s.baselineShift
            foregroundColor = s.foregroundColor; backgroundColor = s.backgroundColor
            linkURL = s.linkURL; isSpoiler = s.isSpoiler
        }

        struct Snapshot {
            let bold: Bool, italic: Bool, isCode: Bool, isPreformatted: Bool
            let underline: Bool, strikethrough: Bool
            let baselineShift: Int
            let foregroundColor: NSColor?, backgroundColor: NSColor?
            let linkURL: URL?
            let isSpoiler: Bool
        }
    }

    // MARK: - Tree Walk

    private static func renderChildren(
        of element: Element, into result: NSMutableAttributedString, context: RenderContext
    ) {
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                renderText(textNode, into: result, context: context)
            } else if let child = node as? Element {
                renderElement(child, into: result, context: context)
            }
        }
    }

    private static func renderText(
        _ textNode: TextNode, into result: NSMutableAttributedString, context: RenderContext
    ) {
        let raw: String
        if context.isPreformatted {
            raw = textNode.getWholeText()
        } else {
            // SwiftSoup's .text() normalizes whitespace within inline flow, but
            // whitespace-only text nodes between block elements (e.g. "\n" between
            // <blockquote> and <p>) should be suppressed to avoid stray spaces.
            let whole = textNode.getWholeText()
            if whole.allSatisfy(\.isWhitespace),
               let parent = textNode.parent() as? Element,
               isBlockContainer(parent.tagNameNormal()) {
                return
            }
            raw = textNode.text()
        }
        guard !raw.isEmpty else { return }
        let attrs = currentAttributes(context)
        result.append(NSAttributedString(string: raw, attributes: attrs))
    }

    /// Whether a tag typically contains block-level children, meaning whitespace-only
    /// text nodes between those children are insignificant.
    private static func isBlockContainer(_ tag: String) -> Bool {
        blockTags.contains(tag) || tag == "body"
    }

    private static func renderElement(
        _ element: Element, into result: NSMutableAttributedString, context: RenderContext
    ) {
        let tag = element.tagNameNormal()

        // For disallowed tags, just render children (strip the tag, keep text).
        guard allowedTags.contains(tag) else {
            renderChildren(of: element, into: result, context: context)
            return
        }

        let snap = context.snapshot()
        defer { context.restore(snap) }

        // Pre-element block break.
        if blockTags.contains(tag) {
            if context.suppressNextBlockBreak {
                context.suppressNextBlockBreak = false
            } else {
                ensureBlockBreak(in: result)
            }
        }

        switch tag {
        // -- Inline formatting --
        case "b", "strong":
            context.bold = true
            renderChildren(of: element, into: result, context: context)

        case "i", "em":
            context.italic = true
            renderChildren(of: element, into: result, context: context)

        case "u":
            context.underline = true
            renderChildren(of: element, into: result, context: context)

        case "s", "del":
            context.strikethrough = true
            renderChildren(of: element, into: result, context: context)

        case "code":
            context.isCode = true
            renderChildren(of: element, into: result, context: context)

        case "sub":
            context.baselineShift -= 1
            renderChildren(of: element, into: result, context: context)

        case "sup":
            context.baselineShift += 1
            renderChildren(of: element, into: result, context: context)

        case "br":
            result.append(NSAttributedString(string: "\n", attributes: currentAttributes(context)))

        case "a":
            if let href = try? element.attr("href"), !href.isEmpty,
               let url = URL(string: href),
               let scheme = url.scheme?.lowercased(),
               allowedLinkSchemes.contains(scheme) {
                context.linkURL = url
            }
            renderChildren(of: element, into: result, context: context)

        case "span":
            applySpanAttributes(element, context: context)
            renderChildren(of: element, into: result, context: context)

        case "font":
            // Deprecated tag -- support reading for backward compat.
            applyFontAttributes(element, context: context)
            renderChildren(of: element, into: result, context: context)

        // -- Block elements --
        case "p", "div":
            renderChildren(of: element, into: result, context: context)
            ensureBlockBreak(in: result)

        case "blockquote":
            context.blockquoteDepth += 1
            renderBlockquote(element, into: result, context: context)

        case "pre":
            context.isPreformatted = true
            context.isCode = true
            renderPreBlock(element, into: result, context: context)

        case "h1": renderHeading(element, level: 1, into: result, context: context)
        case "h2": renderHeading(element, level: 2, into: result, context: context)
        case "h3": renderHeading(element, level: 3, into: result, context: context)
        case "h4": renderHeading(element, level: 4, into: result, context: context)
        case "h5": renderHeading(element, level: 5, into: result, context: context)
        case "h6": renderHeading(element, level: 6, into: result, context: context)

        case "hr":
            let separator = NSAttributedString(
                string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.separatorColor,
                ]
            )
            result.append(separator)

        case "ul":
            context.listStack.append((ordered: false, counter: 0, start: 1))
            renderChildren(of: element, into: result, context: context)
            context.listStack.removeLast()

        case "ol":
            let startValue = (try? element.attr("start")).flatMap(Int.init) ?? 1
            context.listStack.append((ordered: true, counter: startValue - 1, start: startValue))
            renderChildren(of: element, into: result, context: context)
            context.listStack.removeLast()

        case "li":
            renderListItem(element, into: result, context: context)

        default:
            renderChildren(of: element, into: result, context: context)
        }

        // Post-element block break for tags that need it (p, div already handled above).
        if tag == "blockquote" || tag == "pre" || tag.hasPrefix("h") || tag == "ul" || tag == "ol" {
            ensureBlockBreak(in: result)
        }
    }

    // MARK: - Attribute Builders

    private static func currentAttributes(_ context: RenderContext) -> [NSAttributedString.Key: Any] {
        let baseSize = NSFont.systemFontSize
        var attrs: [NSAttributedString.Key: Any] = [:]

        // Font
        let font: NSFont
        if context.isCode || context.isPreformatted {
            let weight: NSFont.Weight = context.bold ? .bold : .regular
            font = NSFont.monospacedSystemFont(ofSize: baseSize, weight: weight)
        } else {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if context.bold { traits.insert(.bold) }
            if context.italic { traits.insert(.italic) }
            if traits.isEmpty {
                font = NSFont.systemFont(ofSize: baseSize)
            } else {
                let desc = NSFont.systemFont(ofSize: baseSize).fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: desc, size: baseSize) ?? NSFont.systemFont(ofSize: baseSize)
            }
        }

        // Apply size scaling for sub/sup.
        if context.baselineShift != 0 {
            let scaledSize = baseSize * 0.75
            let scaledFont: NSFont
            if context.isCode {
                scaledFont = NSFont.monospacedSystemFont(ofSize: scaledSize, weight: context.bold ? .bold : .regular)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if context.bold { traits.insert(.bold) }
                if context.italic { traits.insert(.italic) }
                let desc = NSFont.systemFont(ofSize: scaledSize).fontDescriptor.withSymbolicTraits(traits)
                scaledFont = NSFont(descriptor: desc, size: scaledSize) ?? NSFont.systemFont(ofSize: scaledSize)
            }
            attrs[.font] = scaledFont

            let offset = context.baselineShift > 0
                ? baseSize * 0.35
                : -(baseSize * 0.15)
            attrs[.baselineOffset] = offset
        } else {
            attrs[.font] = font
        }

        // Decorations
        if context.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if context.strikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        // Colors
        if let fg = context.foregroundColor {
            attrs[.foregroundColor] = fg
        }
        if context.isCode && !context.isPreformatted {
            // Inline code background.
            attrs[.backgroundColor] = NSColor.gray.withAlphaComponent(0.12)
        }
        if let bg = context.backgroundColor {
            attrs[.backgroundColor] = bg
        }

        // Spoiler: obscure text by setting foreground == background.
        if context.isSpoiler {
            let spoilerColor = NSColor.labelColor.withAlphaComponent(0.0)
            attrs[.foregroundColor] = spoilerColor
            attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.8)
            // Store a marker so resolve() knows this is a spoiler.
            attrs[.matrixSpoiler] = true
        }

        // Link
        if let url = context.linkURL {
            attrs[.link] = url
        }

        return attrs
    }

    // MARK: - Span / Font Attribute Helpers

    private static func applySpanAttributes(_ element: Element, context: RenderContext) {
        if let colorHex = try? element.attr("data-mx-color"), !colorHex.isEmpty {
            context.foregroundColor = NSColor(matrixHex: colorHex)
        }
        if let bgHex = try? element.attr("data-mx-bg-color"), !bgHex.isEmpty {
            context.backgroundColor = NSColor(matrixHex: bgHex)
        }
        if element.hasAttr("data-mx-spoiler") {
            context.isSpoiler = true
        }
    }

    private static func applyFontAttributes(_ element: Element, context: RenderContext) {
        // Deprecated <font> tag, read data-mx-color, data-mx-bg-color, and legacy color attr.
        if let colorHex = try? element.attr("data-mx-color"), !colorHex.isEmpty {
            context.foregroundColor = NSColor(matrixHex: colorHex)
        } else if let colorHex = try? element.attr("color"), !colorHex.isEmpty {
            context.foregroundColor = NSColor(matrixHex: colorHex)
        }
        if let bgHex = try? element.attr("data-mx-bg-color"), !bgHex.isEmpty {
            context.backgroundColor = NSColor(matrixHex: bgHex)
        }
    }

    // MARK: - Block Rendering

    private static func renderHeading(
        _ element: Element, level: Int,
        into result: NSMutableAttributedString, context: RenderContext
    ) {
        context.bold = true

        let scales: [CGFloat] = [1.5, 1.35, 1.2, 1.1, 1.05, 1.0]
        let scale = scales[min(level - 1, scales.count - 1)]
        let headingSize = NSFont.systemFontSize * scale

        let startIndex = result.length
        renderChildren(of: element, into: result, context: context)
        let range = NSRange(location: startIndex, length: result.length - startIndex)
        guard range.length > 0 else { return }

        // Override the font to the heading size (bold) across the entire heading range.
        let headingFont = NSFont.boldSystemFont(ofSize: headingSize)
        result.addAttribute(.font, value: headingFont, range: range)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 2
        result.addAttribute(.paragraphStyle, value: style, range: range)
    }

    private static func renderBlockquote(
        _ element: Element, into result: NSMutableAttributedString, context: RenderContext
    ) {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        // Measure the width of "│ " to use as the hanging indent.
        let barString = "\u{2502} " // "│ " (box-drawing light vertical + space)
        let barWidth = (barString as NSString).size(withAttributes: [.font: baseFont]).width

        // Build a paragraph style with a hanging indent: the first line starts
        // at 0 (showing the bar), and continuation lines indent past the bar.
        // A negative tailIndent insets the trailing edge by the same amount as the
        // bar width so the text content is visually balanced within the bubble.
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = barWidth
        style.tailIndent = -barWidth

        // Insert the bar character.
        let barAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .blockquoteBar: true,
            .paragraphStyle: style,
        ]
        result.append(NSAttributedString(string: barString, attributes: barAttrs))

        // Suppress the block break that the first child element (typically <p>)
        // would insert, so the text flows on the same line as the bar.
        context.suppressNextBlockBreak = true

        let contentStart = result.length
        renderChildren(of: element, into: result, context: context)

        let contentRange = NSRange(location: contentStart, length: result.length - contentStart)
        guard contentRange.length > 0 else { return }

        // Mark the content with blockquote depth so applyColorOverrides can mute it,
        // and apply the same paragraph style for consistent wrapping.
        result.addAttribute(.blockquoteDepth, value: context.blockquoteDepth, range: contentRange)
        result.addAttribute(.paragraphStyle, value: style, range: contentRange)
    }

    private static func renderPreBlock(
        _ element: Element, into result: NSMutableAttributedString, context: RenderContext
    ) {
        let startIndex = result.length

        // If <pre> contains a <code>, render the <code>'s children directly
        // to avoid double-nesting the code style.
        if let codeChild = try? element.select("code").first() {
            renderChildren(of: codeChild, into: result, context: context)
        } else {
            renderChildren(of: element, into: result, context: context)
        }

        let range = NSRange(location: startIndex, length: result.length - startIndex)
        guard range.length > 0 else { return }

        // Code block background.
        result.addAttribute(.backgroundColor, value: NSColor.gray.withAlphaComponent(0.12), range: range)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 4
        result.addAttribute(.paragraphStyle, value: style, range: range)
    }

    private static func renderListItem(
        _ element: Element, into result: NSMutableAttributedString, context: RenderContext
    ) {
        guard !context.listStack.isEmpty else {
            // <li> outside a list -- just render children.
            renderChildren(of: element, into: result, context: context)
            return
        }

        let depth = context.listStack.count

        // Determine bullet or number.
        let lastIndex = context.listStack.count - 1
        let marker: String
        if context.listStack[lastIndex].ordered {
            context.listStack[lastIndex].counter += 1
            let number = context.listStack[lastIndex].counter
            marker = "\(number). "
        } else {
            let bullets = ["\u{2022}", "\u{25E6}", "\u{2023}"] // •, ◦, ‣
            marker = "\(bullets[min(depth - 1, bullets.count - 1)]) "
        }

        // Ensure we're on a new line.
        ensureNewline(in: result)

        // Prefix the marker directly (no tab indirection). The paragraph style
        // provides a hanging indent so wrapped continuation lines align with the
        // text after the marker, not the marker itself.
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let markerWidth = (marker as NSString).size(withAttributes: [.font: baseFont]).width
        let basePad: CGFloat = 6.0  // Small leading indent from the bubble edge.
        let leadingPad: CGFloat = basePad + CGFloat(depth - 1) * 12.0
        let contentIndent = leadingPad + markerWidth

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = leadingPad
        style.headIndent = contentIndent

        // Append marker.
        let markerAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .paragraphStyle: style,
        ]
        result.append(NSAttributedString(string: marker, attributes: markerAttrs))

        // Render children.
        let contentStart = result.length
        renderChildren(of: element, into: result, context: context)

        // Apply paragraph style to the entire list item content.
        let contentRange = NSRange(location: contentStart, length: result.length - contentStart)
        if contentRange.length > 0 {
            result.addAttribute(.paragraphStyle, value: style, range: contentRange)
        }
    }

    // MARK: - Block Break Helpers

    /// Ensures the result ends with a newline before a new block element.
    private static func ensureBlockBreak(in result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let lastChar = result.attributedSubstring(from: NSRange(location: result.length - 1, length: 1)).string
        if lastChar != "\n" {
            result.append(NSAttributedString(string: "\n"))
        }
    }

    /// Ensures the result ends with a newline (single).
    private static func ensureNewline(in result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let lastChar = result.attributedSubstring(from: NSRange(location: result.length - 1, length: 1)).string
        if lastChar != "\n" {
            result.append(NSAttributedString(string: "\n"))
        }
    }

    /// Remove trailing newlines from the final result.
    private static func trimTrailingNewlines(_ result: NSMutableAttributedString) {
        while result.length > 0 {
            let lastChar = result.attributedSubstring(from: NSRange(location: result.length - 1, length: 1)).string
            if lastChar == "\n" {
                result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
            } else {
                break
            }
        }
    }
}

// MARK: - Custom Attributed String Keys

extension NSAttributedString.Key {
    /// Marker attribute for spoiler text. When present, ``MessageTextView`` can
    /// implement tap-to-reveal behavior.
    static let matrixSpoiler = NSAttributedString.Key("matrixSpoiler")

    /// Tracks blockquote depth for muted text coloring. The value is an `Int`.
    static let blockquoteDepth = NSAttributedString.Key("matrixBlockquoteDepth")

    /// Marks the "| " bar character at the start of a blockquote. The value is `true`.
    static let blockquoteBar = NSAttributedString.Key("matrixBlockquoteBar")
}

// MARK: - NSColor Hex Initializer

extension NSColor {
    /// Creates a color from a Matrix hex color string (e.g. `"#ff0000"` or `"ff0000"`).
    convenience init?(matrixHex hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") {
            cleaned = String(cleaned.dropFirst())
        }
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16)
        else { return nil }

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
