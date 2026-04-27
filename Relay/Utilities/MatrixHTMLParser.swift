// swiftlint:disable file_length
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

// MARK: - Matrix Attributed String Keys

extension NSAttributedString.Key {
    /// Marker attribute for spoiler text (`<span data-mx-spoiler>`).
    /// Value: `Bool`. When `true`, ``MessageTextView`` can implement
    /// tap-to-reveal behavior.
    static let matrixSpoiler = NSAttributedString.Key("matrixSpoiler")

    /// Blockquote nesting depth. Value: `Int` (1 for outermost, 2 for nested, etc.).
    /// Used by ``MessageTextView/applyColorOverrides(_:foreground:linkColor:)``
    /// to mute text color inside blockquotes.
    static let blockquoteDepth = NSAttributedString.Key("matrixBlockquoteDepth")

    /// Marks the bar character(s) at the start of a blockquote. Value: `Bool`.
    /// Used by ``MessageTextView/applyColorOverrides(_:foreground:linkColor:)``
    /// to apply a subtle foreground color to the vertical bar.
    static let blockquoteBar = NSAttributedString.Key("matrixBlockquoteBar")
}

// MARK: - NSAttributedString + Matrix HTML

extension NSAttributedString {

    /// Creates an attributed string by parsing a Matrix `org.matrix.custom.html`
    /// formatted message body.
    ///
    /// Supports the subset of HTML tags recommended by the
    /// [Matrix Client-Server API specification](https://spec.matrix.org/latest/client-server-api/#mroommessage-msgtypes):
    ///
    /// **Inline:** `b`, `strong`, `i`, `em`, `u`, `s`, `del`, `code`, `a`, `span`,
    ///             `sub`, `sup`, `br`, `font` (deprecated)
    ///
    /// **Block:** `p`, `div`, `blockquote`, `pre`, `h1`-`h6`, `hr`, `ul`, `ol`, `li`
    ///
    /// Tags outside this set are stripped (their text content is preserved).
    /// The `<mx-reply>` block is removed per the spec.
    ///
    /// - Parameter matrixHTML: The raw HTML string from a `formatted_body` field.
    convenience init?(matrixHTML html: String) {
        let parser = MatrixHTMLParser(html)
        guard let result = parser.parse() else { return nil }
        self.init(attributedString: result)
    }

    /// Creates an attributed string by parsing a Matrix message plain-text
    /// `body` field as inline Markdown, resolving `InlinePresentationIntent`
    /// attributes into concrete AppKit fonts/decorations, and linking bare
    /// URLs and Matrix identifiers.
    ///
    /// - Parameter matrixMarkdown: The raw body string (not HTML).
    convenience init(matrixMarkdown body: String) {
        let resolved = Self.resolveMarkdown(body)
        self.init(attributedString: resolved)
    }

    /// Parses inline Markdown, detects bare URLs and Matrix identifiers,
    /// and resolves all `InlinePresentationIntent` attributes into AppKit
    /// font traits and decorations, producing an `NSAttributedString` ready
    /// for rendering.
    private static func resolveMarkdown(_ raw: String) -> NSAttributedString {
        // 1. Parse inline Markdown into an AttributedString.
        var source: AttributedString
        if let md = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            source = md
        } else {
            source = AttributedString(raw)
        }

        // 2. Detect bare URLs with NSDataDetector.
        let plainString = String(source.characters)
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) {
            let matches = detector.matches(
                in: plainString,
                range: NSRange(plainString.startIndex..., in: plainString)
            )
            for match in matches {
                guard let urlRange = Range(match.range, in: plainString),
                      let attrRange = Range(urlRange, in: source)
                else { continue }
                if source[attrRange].link == nil {
                    source[attrRange].link = match.url
                }
            }
        }

        // 3. Link bare Matrix identifiers (@user:server, #room:server, etc.).
        MatrixIdentifierLinker.linkify(&source)

        // 4. Bridge to NSAttributedString and resolve InlinePresentationIntent
        //    into concrete AppKit fonts and decorations.
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(source))
        let fullRange = NSRange(location: 0, length: result.length)

        // Ensure every range has a font.
        result.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                result.addAttribute(.font, value: baseFont, range: range)
            }
        }

        // Resolve InlinePresentationIntent → font traits + decorations.
        result.enumerateAttribute(
            .inlinePresentationIntent, in: fullRange, options: []
        ) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)

            if intent.contains(.code) {
                let mono = NSFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize, weight: .regular
                )
                result.addAttribute(.font, value: mono, range: range)
                result.addAttribute(
                    .backgroundColor,
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
                    result.addAttribute(.font, value: font, range: range)
                }
            }

            if intent.contains(.strikethrough) {
                result.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }

        return result
    }
}

// MARK: - MatrixHTMLParser

/// Internal parser that converts Matrix HTML into `NSAttributedString`.
///
/// Uses a lightweight scanner to tokenize HTML into tags and text segments,
/// then maps the limited Matrix tag set directly to AppKit attributes. No
/// external dependencies — just Swift string processing and AppKit types.
private struct MatrixHTMLParser { // swiftlint:disable:this type_body_length

    private let html: String

    init(_ html: String) {
        self.html = html
    }

    // MARK: - Allowed Tags

    /// Tags we actively render. Everything else is stripped (text preserved).
    private static let allowedTags: Set<String> = [
        "b", "strong", "i", "em", "u", "s", "del", "code", "a", "span",
        "sub", "sup", "br", "font",
        "p", "div", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "ul", "ol", "li"
    ]

    /// Tags that introduce block-level breaks.
    private static let blockTags: Set<String> = [
        "p", "div", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "ul", "ol", "li"
    ]

    /// Void (self-closing) tags that have no closing counterpart.
    private static let voidTags: Set<String> = ["br", "hr"]

    /// Tags whose content (including text children) should be suppressed entirely.
    private static let opaqueContentTags: Set<String> = [
        "script", "style", "title", "head"
    ]

    /// Allowed URL schemes for `<a href>` links (per spec).
    private static let allowedLinkSchemes: Set<String> = [
        "https", "http", "ftp", "mailto", "magnet"
    ]

    // MARK: - Render State

    /// Per-element formatting state, pushed/popped as tags open/close.
    private struct Style {
        var bold = false
        var italic = false
        var isCode = false
        var isPreformatted = false
        var underline = false
        var strikethrough = false
        var baselineShift: Int = 0
        var foregroundColor: NSColor?
        var backgroundColor: NSColor?
        var linkURL: URL?
        var isSpoiler = false
    }

    // MARK: - Token Types

    /// A simple HTML token produced by the scanner.
    private enum Token {
        case text(String)
        case openTag(name: String, attributes: [String: String])
        case closeTag(name: String)
    }

    // MARK: - Parse Entry Point

    func parse() -> NSAttributedString? {
        // Strip <mx-reply>...</mx-reply> blocks per spec.
        let cleaned = removeMxReply(html)

        let tokens = tokenize(cleaned)
        let result = NSMutableAttributedString()
        var styleStack: [Style] = [Style()]
        var blockquoteDepth = 0
        var listStack: [(ordered: Bool, counter: Int)] = []
        var suppressNextBlockBreak = false
        /// Nesting depth inside tags whose content should be suppressed (e.g. `<script>`).
        var opaqueDepth = 0

        // Deferred block-element post-processing (headings, blockquotes, pre, list items).
        struct DeferredBlock {
            let tag: String
            let startIndex: Int
            var attributes: [String: String] = [:]
        }
        var deferredStack: [DeferredBlock] = []

        for token in tokens {
            switch token {
            case .text(let text):
                // Suppress text inside opaque-content tags like <script>.
                guard opaqueDepth == 0 else { continue }

                let current = styleStack.last!
                let processed: String
                if current.isPreformatted {
                    processed = text
                } else {
                    // Collapse whitespace in non-preformatted context.
                    let collapsed = collapseWhitespace(text)
                    // Suppress whitespace-only text between block elements.
                    if collapsed.allSatisfy(\.isWhitespace) && result.length > 0 {
                        let lastChar = result.attributedSubstring(
                            from: NSRange(location: result.length - 1, length: 1)
                        ).string
                        if lastChar == "\n" { continue }
                    }
                    processed = collapsed
                }
                guard !processed.isEmpty else { continue }
                let attrs = buildAttributes(from: current)
                result.append(NSAttributedString(string: processed, attributes: attrs))

            case .openTag(let name, let attributes):
                let tag = name.lowercased()

                // Track nesting into opaque-content tags.
                if Self.opaqueContentTags.contains(tag) {
                    opaqueDepth += 1
                    continue
                }
                guard opaqueDepth == 0 else { continue }

                guard Self.allowedTags.contains(tag) else { continue }

                // Pre-element block break.
                if Self.blockTags.contains(tag) {
                    if suppressNextBlockBreak {
                        suppressNextBlockBreak = false
                    } else {
                        ensureBlockBreak(in: result)
                    }
                }

                // Push a copy of the current style.
                var style = styleStack.last!

                switch tag {
                case "b", "strong":
                    style.bold = true
                case "i", "em":
                    style.italic = true
                case "u":
                    style.underline = true
                case "s", "del":
                    style.strikethrough = true
                case "code":
                    style.isCode = true
                case "sub":
                    style.baselineShift -= 1
                case "sup":
                    style.baselineShift += 1
                case "br":
                    let attrs = buildAttributes(from: style)
                    result.append(NSAttributedString(string: "\n", attributes: attrs))
                case "a":
                    if let href = attributes["href"], !href.isEmpty,
                       let url = URL(string: href),
                       let scheme = url.scheme?.lowercased(),
                       Self.allowedLinkSchemes.contains(scheme) {
                        style.linkURL = url
                    }
                case "span":
                    if let colorHex = attributes["data-mx-color"], !colorHex.isEmpty {
                        style.foregroundColor = NSColor(matrixHex: colorHex)
                    }
                    if let bgHex = attributes["data-mx-bg-color"], !bgHex.isEmpty {
                        style.backgroundColor = NSColor(matrixHex: bgHex)
                    }
                    if attributes.keys.contains("data-mx-spoiler") {
                        style.isSpoiler = true
                    }
                case "font":
                    if let colorHex = attributes["data-mx-color"], !colorHex.isEmpty {
                        style.foregroundColor = NSColor(matrixHex: colorHex)
                    } else if let colorHex = attributes["color"], !colorHex.isEmpty {
                        style.foregroundColor = NSColor(matrixHex: colorHex)
                    }
                    if let bgHex = attributes["data-mx-bg-color"], !bgHex.isEmpty {
                        style.backgroundColor = NSColor(matrixHex: bgHex)
                    }

                case "blockquote":
                    blockquoteDepth += 1
                    let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                    let barString = "\u{2502} "
                    let barWidth = (barString as NSString)
                        .size(withAttributes: [.font: baseFont]).width
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.firstLineHeadIndent = 0
                    paraStyle.headIndent = barWidth
                    paraStyle.tailIndent = -barWidth
                    let barAttrs: [NSAttributedString.Key: Any] = [
                        .font: baseFont,
                        .blockquoteBar: true,
                        .paragraphStyle: paraStyle
                    ]
                    result.append(NSAttributedString(string: barString, attributes: barAttrs))
                    suppressNextBlockBreak = true
                    deferredStack.append(DeferredBlock(
                        tag: tag, startIndex: result.length
                    ))

                case "pre":
                    style.isPreformatted = true
                    style.isCode = true
                    deferredStack.append(DeferredBlock(tag: tag, startIndex: result.length))

                case "h1", "h2", "h3", "h4", "h5", "h6":
                    style.bold = true
                    deferredStack.append(DeferredBlock(tag: tag, startIndex: result.length))

                case "hr":
                    let separator = NSAttributedString(
                        string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                            .foregroundColor: NSColor.separatorColor
                        ]
                    )
                    result.append(separator)

                case "ul":
                    listStack.append((ordered: false, counter: 0))
                case "ol":
                    let startValue = attributes["start"].flatMap(Int.init) ?? 1
                    listStack.append((ordered: true, counter: startValue - 1))

                case "li":
                    if !listStack.isEmpty {
                        let depth = listStack.count
                        let lastIndex = listStack.count - 1
                        let marker: String
                        if listStack[lastIndex].ordered {
                            listStack[lastIndex].counter += 1
                            marker = "\(listStack[lastIndex].counter). "
                        } else {
                            let bullets = ["\u{2022}", "\u{25E6}", "\u{2023}"]
                            marker = "\(bullets[min(depth - 1, bullets.count - 1)]) "
                        }
                        ensureNewline(in: result)
                        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                        let markerWidth = (marker as NSString)
                            .size(withAttributes: [.font: baseFont]).width
                        let basePad: CGFloat = 6.0
                        let leadingPad: CGFloat = basePad + CGFloat(depth - 1) * 12.0
                        let contentIndent = leadingPad + markerWidth
                        let paraStyle = NSMutableParagraphStyle()
                        paraStyle.firstLineHeadIndent = leadingPad
                        paraStyle.headIndent = contentIndent
                        let markerAttrs: [NSAttributedString.Key: Any] = [
                            .font: baseFont,
                            .paragraphStyle: paraStyle
                        ]
                        result.append(NSAttributedString(string: marker, attributes: markerAttrs))
                        deferredStack.append(DeferredBlock(tag: tag, startIndex: result.length))
                    }
                default:
                    break
                }

                // Push style for non-void tags.
                if !Self.voidTags.contains(tag) {
                    styleStack.append(style)
                }

            case .closeTag(let name):
                let tag = name.lowercased()

                // Track leaving opaque-content tags.
                if Self.opaqueContentTags.contains(tag) {
                    opaqueDepth = max(0, opaqueDepth - 1)
                    continue
                }
                guard opaqueDepth == 0 else { continue }

                guard Self.allowedTags.contains(tag), !Self.voidTags.contains(tag) else {
                    continue
                }

                switch tag {
                case "p", "div":
                    ensureBlockBreak(in: result)

                case "blockquote":
                    if let deferred = deferredStack.last, deferred.tag == "blockquote" {
                        deferredStack.removeLast()
                        let contentRange = NSRange(
                            location: deferred.startIndex,
                            length: result.length - deferred.startIndex
                        )
                        if contentRange.length > 0 {
                            // Apply depth only where a nested blockquote hasn't
                            // already set a higher value.
                            result.enumerateAttribute(
                                .blockquoteDepth, in: contentRange, options: []
                            ) { value, range, _ in
                                let existing = value as? Int ?? 0
                                if blockquoteDepth > existing {
                                    result.addAttribute(
                                        .blockquoteDepth,
                                        value: blockquoteDepth,
                                        range: range
                                    )
                                }
                            }
                            // Apply paragraph style for blockquote wrapping.
                            let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                            let barWidth = ("\u{2502} " as NSString)
                                .size(withAttributes: [.font: baseFont]).width
                            let style = NSMutableParagraphStyle()
                            style.firstLineHeadIndent = 0
                            style.headIndent = barWidth
                            style.tailIndent = -barWidth
                            result.addAttribute(
                                .paragraphStyle, value: style, range: contentRange
                            )
                        }
                    }
                    blockquoteDepth -= 1
                    ensureBlockBreak(in: result)

                case "pre":
                    if let deferred = deferredStack.last, deferred.tag == "pre" {
                        deferredStack.removeLast()
                        let range = NSRange(
                            location: deferred.startIndex,
                            length: result.length - deferred.startIndex
                        )
                        if range.length > 0 {
                            result.addAttribute(
                                .backgroundColor,
                                value: NSColor.gray.withAlphaComponent(0.12),
                                range: range
                            )
                            let style = NSMutableParagraphStyle()
                            style.paragraphSpacingBefore = 4
                            style.paragraphSpacing = 4
                            result.addAttribute(.paragraphStyle, value: style, range: range)
                        }
                    }
                    ensureBlockBreak(in: result)

                case "h1", "h2", "h3", "h4", "h5", "h6":
                    if let deferred = deferredStack.last, deferred.tag == tag {
                        deferredStack.removeLast()
                        let range = NSRange(
                            location: deferred.startIndex,
                            length: result.length - deferred.startIndex
                        )
                        if range.length > 0 {
                            let level = Int(String(tag.last!))!
                            let scales: [CGFloat] = [1.5, 1.35, 1.2, 1.1, 1.05, 1.0]
                            let scale = scales[min(level - 1, scales.count - 1)]
                            let headingSize = NSFont.systemFontSize * scale
                            let headingFont = NSFont.boldSystemFont(ofSize: headingSize)
                            result.addAttribute(.font, value: headingFont, range: range)
                            let style = NSMutableParagraphStyle()
                            style.paragraphSpacingBefore = 4
                            style.paragraphSpacing = 2
                            result.addAttribute(.paragraphStyle, value: style, range: range)
                        }
                    }
                    ensureBlockBreak(in: result)

                case "ul", "ol":
                    if !listStack.isEmpty {
                        listStack.removeLast()
                    }
                    ensureBlockBreak(in: result)

                case "li":
                    if let deferred = deferredStack.last, deferred.tag == "li" {
                        deferredStack.removeLast()
                        let contentRange = NSRange(
                            location: deferred.startIndex,
                            length: result.length - deferred.startIndex
                        )
                        if contentRange.length > 0 {
                            // Re-derive the paragraph style for this list depth.
                            let depth = listStack.count
                            if depth > 0 {
                                let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                                // Use a placeholder marker to measure width consistently.
                                let sampleMarker = listStack[depth - 1].ordered ? "0. " : "\u{2022} "
                                let markerWidth = (sampleMarker as NSString)
                                    .size(withAttributes: [.font: baseFont]).width
                                let basePad: CGFloat = 6.0
                                let leadingPad = basePad + CGFloat(depth - 1) * 12.0
                                let contentIndent = leadingPad + markerWidth
                                let style = NSMutableParagraphStyle()
                                style.firstLineHeadIndent = leadingPad
                                style.headIndent = contentIndent
                                result.addAttribute(
                                    .paragraphStyle, value: style, range: contentRange
                                )
                            }
                        }
                    }

                default:
                    break
                }

                // Pop style.
                if styleStack.count > 1 {
                    styleStack.removeLast()
                }
            }
        }

        // Trim trailing newlines.
        while result.length > 0 {
            let last = result.attributedSubstring(
                from: NSRange(location: result.length - 1, length: 1)
            ).string
            if last == "\n" {
                result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
            } else {
                break
            }
        }

        if result.length == 0 { return nil }

        // Detect bare URLs that are not wrapped in <a> tags.
        // This covers cases where the sending client includes a URL as plain
        // text in the `formatted_body` HTML (e.g. alongside mention links).
        // Since the text view disables automatic link detection, we must
        // handle this ourselves, mirroring the NSDataDetector pass in
        // resolveMarkdown().
        linkBareURLs(in: result)

        return result
    }

    // MARK: - Attribute Builder

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func buildAttributes(from style: Style) -> [NSAttributedString.Key: Any] {
        let baseSize = NSFont.systemFontSize
        var attrs: [NSAttributedString.Key: Any] = [:]

        // Font
        let font: NSFont
        if style.isCode || style.isPreformatted {
            let weight: NSFont.Weight = style.bold ? .bold : .regular
            font = NSFont.monospacedSystemFont(ofSize: baseSize, weight: weight)
        } else {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if style.bold { traits.insert(.bold) }
            if style.italic { traits.insert(.italic) }
            if traits.isEmpty {
                font = NSFont.systemFont(ofSize: baseSize)
            } else {
                let desc = NSFont.systemFont(ofSize: baseSize)
                    .fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: desc, size: baseSize)
                    ?? NSFont.systemFont(ofSize: baseSize)
            }
        }

        // Apply size scaling for sub/sup.
        if style.baselineShift != 0 {
            let scaledSize = baseSize * 0.75
            let scaledFont: NSFont
            if style.isCode {
                scaledFont = NSFont.monospacedSystemFont(
                    ofSize: scaledSize, weight: style.bold ? .bold : .regular
                )
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if style.bold { traits.insert(.bold) }
                if style.italic { traits.insert(.italic) }
                let desc = NSFont.systemFont(ofSize: scaledSize)
                    .fontDescriptor.withSymbolicTraits(traits)
                scaledFont = NSFont(descriptor: desc, size: scaledSize)
                    ?? NSFont.systemFont(ofSize: scaledSize)
            }
            attrs[.font] = scaledFont
            let offset = style.baselineShift > 0
                ? baseSize * 0.35
                : -(baseSize * 0.15)
            attrs[.baselineOffset] = offset
        } else {
            attrs[.font] = font
        }

        // Decorations
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.strikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        // Colors
        if let fg = style.foregroundColor {
            attrs[.foregroundColor] = fg
        }
        if style.isCode && !style.isPreformatted {
            attrs[.backgroundColor] = NSColor.gray.withAlphaComponent(0.12)
        }
        if let bg = style.backgroundColor {
            attrs[.backgroundColor] = bg
        }

        // Spoiler
        if style.isSpoiler {
            attrs[.foregroundColor] = NSColor.labelColor.withAlphaComponent(0.0)
            attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.8)
            attrs[.matrixSpoiler] = true
        }

        // Link
        if let url = style.linkURL {
            attrs[.link] = url
        }

        return attrs
    }

    // MARK: - HTML Tokenizer

    /// Tokenizes HTML into a sequence of text, open-tag, and close-tag tokens.
    /// Handles entity decoding, attribute parsing, and self-closing tags.
    private func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var index = html.startIndex

        while index < html.endIndex {
            if html[index] == "<" {
                // Try to parse a tag.
                if let tagEnd = html[index...].firstIndex(of: ">") {
                    let tagContent = html[html.index(after: index)..<tagEnd]
                    let tagString = String(tagContent).trimmingCharacters(in: .whitespaces)

                    if tagString.hasPrefix("!--") {
                        // HTML comment — skip entirely.
                        if let commentEnd = html[index...].range(of: "-->") {
                            index = commentEnd.upperBound
                        } else {
                            index = html.endIndex
                        }
                        continue
                    } else if tagString.hasPrefix("!") || tagString.hasPrefix("?") {
                        // Doctype or processing instruction — skip.
                        index = html.index(after: tagEnd)
                        continue
                    } else if tagString.hasPrefix("/") {
                        // Close tag.
                        let name = String(tagString.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                            .lowercased()
                            .split(separator: " ").first
                            .map(String.init) ?? ""
                        if !name.isEmpty {
                            tokens.append(.closeTag(name: name))
                        }
                    } else {
                        // Open tag (possibly self-closing).
                        let (name, attributes) = parseTagContent(tagString)
                        let lowerName = name.lowercased()
                        tokens.append(.openTag(name: lowerName, attributes: attributes))
                        // If self-closing or a void element, auto-close.
                        if tagString.hasSuffix("/") || Self.voidTags.contains(lowerName) {
                            // Void tags don't get a close token — handled by not pushing style.
                        }
                    }
                    index = html.index(after: tagEnd)
                } else {
                    // Malformed: < without matching >. Treat as text.
                    tokens.append(.text(String(html[index])))
                    index = html.index(after: index)
                }
            } else {
                // Accumulate text until the next tag.
                var textEnd = index
                while textEnd < html.endIndex && html[textEnd] != "<" {
                    textEnd = html.index(after: textEnd)
                }
                let rawText = String(html[index..<textEnd])
                let decoded = decodeHTMLEntities(rawText)
                tokens.append(.text(decoded))
                index = textEnd
            }
        }

        return tokens
    }

    /// Parses the content inside `< ... >` into a tag name and attribute dictionary.
    private func parseTagContent(_ content: String) -> (name: String, attributes: [String: String]) {
        // Remove trailing / for self-closing tags.
        var cleaned = content
        if cleaned.hasSuffix("/") {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        // Split into parts: first is the tag name, rest are attributes.
        var index = cleaned.startIndex
        // Find end of tag name.
        while index < cleaned.endIndex && !cleaned[index].isWhitespace {
            index = cleaned.index(after: index)
        }
        let name = String(cleaned[cleaned.startIndex..<index])

        // Parse attributes.
        var attributes: [String: String] = [:]
        var remaining = cleaned[index...].trimmingCharacters(in: .whitespaces)

        while !remaining.isEmpty {
            // Find attribute name.
            guard let eqIndex = remaining.firstIndex(of: "=") else {
                // Bare attribute (e.g. `data-mx-spoiler` without a value).
                let attrName = remaining.trimmingCharacters(in: .whitespaces).lowercased()
                if !attrName.isEmpty {
                    attributes[attrName] = ""
                }
                break
            }

            let attrName = remaining[remaining.startIndex..<eqIndex]
                .trimmingCharacters(in: .whitespaces).lowercased()
            var afterEq = remaining[remaining.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)

            let value: String
            if afterEq.hasPrefix("\"") {
                afterEq = String(afterEq.dropFirst())
                if let closeQuote = afterEq.firstIndex(of: "\"") {
                    value = String(afterEq[afterEq.startIndex..<closeQuote])
                    remaining = String(
                        afterEq[afterEq.index(after: closeQuote)...]
                    ).trimmingCharacters(in: .whitespaces)
                } else {
                    value = afterEq
                    remaining = ""
                }
            } else if afterEq.hasPrefix("'") {
                afterEq = String(afterEq.dropFirst())
                if let closeQuote = afterEq.firstIndex(of: "'") {
                    value = String(afterEq[afterEq.startIndex..<closeQuote])
                    remaining = String(
                        afterEq[afterEq.index(after: closeQuote)...]
                    ).trimmingCharacters(in: .whitespaces)
                } else {
                    value = afterEq
                    remaining = ""
                }
            } else {
                // Unquoted value — read until whitespace.
                if let spaceIndex = afterEq.firstIndex(where: \.isWhitespace) {
                    value = String(afterEq[afterEq.startIndex..<spaceIndex])
                    remaining = String(
                        afterEq[spaceIndex...]
                    ).trimmingCharacters(in: .whitespaces)
                } else {
                    value = afterEq
                    remaining = ""
                }
            }

            if !attrName.isEmpty {
                attributes[attrName] = decodeHTMLEntities(value)
            }
        }

        return (name, attributes)
    }

    // MARK: - Preprocessing

    /// Removes `<mx-reply>...</mx-reply>` blocks from the HTML string.
    private func removeMxReply(_ html: String) -> String {
        guard let openRange = html.range(
            of: "<mx-reply>", options: .caseInsensitive
        ) else { return html }

        if let closeRange = html.range(
            of: "</mx-reply>", options: .caseInsensitive,
            range: openRange.upperBound..<html.endIndex
        ) {
            var result = html
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            return result
        }
        // Unclosed mx-reply — remove from open tag to end.
        var result = html
        result.removeSubrange(openRange.lowerBound..<html.endIndex)
        return result
    }

    // MARK: - HTML Entity Decoding

    /// Decodes common HTML entities and numeric character references.
    private func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = text
        // Named entities (common subset).
        result = result.replacing("&amp;", with: "&")
        result = result.replacing("&lt;", with: "<")
        result = result.replacing("&gt;", with: ">")
        result = result.replacing("&quot;", with: "\"")
        result = result.replacing("&apos;", with: "'")
        result = result.replacing("&nbsp;", with: "\u{00A0}")

        // Numeric character references: &#123; or &#x1F4A9;
        result = decodeNumericEntities(result)

        return result
    }

    /// Decodes `&#NNN;` and `&#xHHH;` numeric character references.
    private func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "&",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "#" {
                // Try to parse numeric entity.
                let entityStart = index
                index = text.index(index, offsetBy: 2)
                let isHex = index < text.endIndex && (text[index] == "x" || text[index] == "X")
                if isHex { index = text.index(after: index) }

                var digits = ""
                while index < text.endIndex && text[index] != ";" {
                    digits.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex && text[index] == ";" {
                    index = text.index(after: index) // skip ;
                    let codePoint = isHex
                        ? UInt32(digits, radix: 16)
                        : UInt32(digits, radix: 10)
                    if let cp = codePoint, let scalar = Unicode.Scalar(cp) {
                        result.append(Character(scalar))
                        continue
                    }
                }
                // Failed to parse — output as-is.
                result.append(contentsOf: text[entityStart..<index])
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    // MARK: - Whitespace Helpers

    /// Collapses runs of whitespace into single spaces (HTML whitespace normalization).
    private func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for char in text {
            if char.isWhitespace || char.isNewline {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.append(char)
                lastWasSpace = false
            }
        }
        return result
    }

    /// Ensures the result ends with a newline before a new block element.
    private func ensureBlockBreak(in result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let lastChar = result.attributedSubstring(
            from: NSRange(location: result.length - 1, length: 1)
        ).string
        if lastChar != "\n" {
            result.append(NSAttributedString(string: "\n"))
        }
    }

    /// Ensures the result ends with a newline (single).
    private func ensureNewline(in result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let lastChar = result.attributedSubstring(
            from: NSRange(location: result.length - 1, length: 1)
        ).string
        if lastChar != "\n" {
            result.append(NSAttributedString(string: "\n"))
        }
    }

    /// Detects bare URLs in the attributed string that are not already
    /// covered by an `<a>` tag and adds a `.link` attribute for them.
    ///
    /// This is needed because `isAutomaticLinkDetectionEnabled` is disabled
    /// on the text view, so any URL not wrapped in an `<a>` tag would be
    /// rendered as unclickable plain text.
    private func linkBareURLs(in result: NSMutableAttributedString) {
        let plainString = result.string
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return }

        let matches = detector.matches(
            in: plainString,
            range: NSRange(location: 0, length: result.length)
        )

        for match in matches {
            // Skip ranges that already have a .link attribute (from <a> tags).
            let existingLink = result.attribute(.link, at: match.range.location, effectiveRange: nil)
            if existingLink != nil { continue }

            if let url = match.url {
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
    }
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
