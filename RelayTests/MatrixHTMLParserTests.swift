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
import Testing

@testable import Relay

// MARK: - MatrixHTMLParserTests

struct MatrixHTMLParserTests {

    init() {
        // MatrixHTMLParser derives heading/base sizes from
        // MessageTextScale.baseFontSize. This test target shares UserDefaults
        // with the app (bundle_loader), so a real, persisted text-zoom level
        // from manual testing would otherwise make size-comparison tests here
        // fail for reasons unrelated to the change under test.
        UserDefaults.standard.removeObject(forKey: MessageTextScale.userDefaultsKey)
    }

    // MARK: - Helpers

    /// Returns attributes at a character offset.
    private func attrs(
        _ str: NSAttributedString, at offset: Int
    ) -> [NSAttributedString.Key: Any] {
        str.attributes(at: offset, effectiveRange: nil)
    }

    /// Returns the font at a character offset.
    private func font(_ str: NSAttributedString, at offset: Int) -> NSFont? {
        attrs(str, at: offset)[.font] as? NSFont
    }

    /// Returns the symbolic traits of the font at a character offset.
    private func traits(
        _ str: NSAttributedString, at offset: Int
    ) -> NSFontDescriptor.SymbolicTraits {
        font(str, at: offset)?.fontDescriptor.symbolicTraits ?? []
    }

    /// Whether the font at offset is a monospaced system font.
    private func isMonospaced(_ str: NSAttributedString, at offset: Int) -> Bool {
        guard let resolvedFont = font(str, at: offset) else { return false }
        return resolvedFont.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    // MARK: - Inline Formatting

    @Test func boldWithBTag() {
        let result = NSAttributedString(matrixHTML:"<b>bold</b>")!
        #expect(result.string == "bold")
        #expect(traits(result, at: 0).contains(.bold))
    }

    @Test func boldWithStrongTag() {
        let result = NSAttributedString(matrixHTML:"<strong>bold</strong>")!
        #expect(result.string == "bold")
        #expect(traits(result, at: 0).contains(.bold))
    }

    @Test func italicWithITag() {
        let result = NSAttributedString(matrixHTML:"<i>italic</i>")!
        #expect(result.string == "italic")
        #expect(traits(result, at: 0).contains(.italic))
    }

    @Test func italicWithEmTag() {
        let result = NSAttributedString(matrixHTML:"<em>italic</em>")!
        #expect(result.string == "italic")
        #expect(traits(result, at: 0).contains(.italic))
    }

    @Test func underline() {
        let result = NSAttributedString(matrixHTML:"<u>text</u>")!
        #expect(result.string == "text")
        let style = attrs(result, at: 0)[.underlineStyle] as? Int
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    @Test func strikethroughWithSTag() {
        let result = NSAttributedString(matrixHTML:"<s>text</s>")!
        #expect(result.string == "text")
        let style = attrs(result, at: 0)[.strikethroughStyle] as? Int
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    @Test func strikethroughWithDelTag() {
        let result = NSAttributedString(matrixHTML:"<del>text</del>")!
        #expect(result.string == "text")
        let style = attrs(result, at: 0)[.strikethroughStyle] as? Int
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    @Test func inlineCode() {
        let result = NSAttributedString(matrixHTML:"<code>x</code>")!
        #expect(result.string == "x")
        #expect(isMonospaced(result, at: 0))
        // Inline code should have a background color.
        let bg = attrs(result, at: 0)[.backgroundColor] as? NSColor
        #expect(bg != nil)
    }

    @Test func subscriptText() {
        let result = NSAttributedString(matrixHTML:"a<sub>2</sub>")!
        #expect(result.string == "a2")
        // "a" at index 0 should have no baseline offset.
        let normalOffset = attrs(result, at: 0)[.baselineOffset] as? Double
        #expect(normalOffset == nil)
        // "2" at index 1 should have a negative baseline offset.
        let subOffset = attrs(result, at: 1)[.baselineOffset] as? Double
        #expect(subOffset != nil)
        #expect(subOffset! < 0)
        // Sub text should be smaller.
        let normalSize = font(result, at: 0)!.pointSize
        let subSize = font(result, at: 1)!.pointSize
        #expect(subSize < normalSize)
    }

    @Test func superscriptText() {
        let result = NSAttributedString(matrixHTML:"x<sup>2</sup>")!
        #expect(result.string == "x2")
        // "2" at index 1 should have a positive baseline offset.
        let supOffset = attrs(result, at: 1)[.baselineOffset] as? Double
        #expect(supOffset != nil)
        #expect(supOffset! > 0)
        // Sup text should be smaller.
        let normalSize = font(result, at: 0)!.pointSize
        let supSize = font(result, at: 1)!.pointSize
        #expect(supSize < normalSize)
    }

    @Test func lineBreak() {
        let result = NSAttributedString(matrixHTML:"a<br>b")!
        #expect(result.string == "a\nb")
    }

    // MARK: - Links

    @Test func validHTTPSLink() {
        let result = NSAttributedString(matrixHTML:
            #"<a href="https://example.com">link</a>"#
        )!
        #expect(result.string == "link")
        let url = attrs(result, at: 0)[.link] as? URL
        #expect(url?.absoluteString == "https://example.com")
    }

    @Test func validHTTPLink() {
        let result = NSAttributedString(matrixHTML:
            #"<a href="http://example.com">link</a>"#
        )!
        let url = attrs(result, at: 0)[.link] as? URL
        #expect(url?.absoluteString == "http://example.com")
    }

    @Test func validMailtoLink() {
        let result = NSAttributedString(matrixHTML:
            #"<a href="mailto:user@example.com">email</a>"#
        )!
        let url = attrs(result, at: 0)[.link] as? URL
        #expect(url?.scheme == "mailto")
    }

    @Test func disallowedSchemeStripped() {
        let result = NSAttributedString(matrixHTML:
            #"<a href="javascript:alert(1)">text</a>"#
        )!
        #expect(result.string == "text")
        let url = attrs(result, at: 0)[.link]
        #expect(url == nil)
    }

    @Test func emptyHrefNoLink() {
        let result = NSAttributedString(matrixHTML:#"<a href="">text</a>"#)!
        #expect(result.string == "text")
        let url = attrs(result, at: 0)[.link]
        #expect(url == nil)
    }

    // MARK: - Colors

    @Test func spanForegroundColor() {
        let result = NSAttributedString(matrixHTML:
            ##"<span data-mx-color="#ff0000">red</span>"##
        )!
        #expect(result.string == "red")
        let color = attrs(result, at: 0)[.foregroundColor] as? NSColor
        #expect(color != nil)
        // Convert to sRGB for comparison.
        let srgb = color!.usingColorSpace(.sRGB)!
        #expect(srgb.redComponent > 0.9)
        #expect(srgb.greenComponent < 0.1)
        #expect(srgb.blueComponent < 0.1)
    }

    @Test func spanBackgroundColor() {
        let result = NSAttributedString(matrixHTML:
            ##"<span data-mx-bg-color="#00ff00">green</span>"##
        )!
        #expect(result.string == "green")
        let color = attrs(result, at: 0)[.backgroundColor] as? NSColor
        #expect(color != nil)
        let srgb = color!.usingColorSpace(.sRGB)!
        #expect(srgb.greenComponent > 0.9)
    }

    @Test func legacyFontColor() {
        let result = NSAttributedString(matrixHTML:
            ##"<font color="#0000ff">blue</font>"##
        )!
        #expect(result.string == "blue")
        let color = attrs(result, at: 0)[.foregroundColor] as? NSColor
        #expect(color != nil)
        let srgb = color!.usingColorSpace(.sRGB)!
        #expect(srgb.blueComponent > 0.9)
        #expect(srgb.redComponent < 0.1)
    }

    // MARK: - Spoilers

    @Test func spoilerAttribute() {
        let result = NSAttributedString(matrixHTML:
            #"<span data-mx-spoiler>secret</span>"#
        )!
        #expect(result.string == "secret")
        let isSpoiler = attrs(result, at: 0)[.matrixSpoiler] as? Bool
        #expect(isSpoiler == true)
    }

    @Test func spoilerHasObscuredColors() {
        let result = NSAttributedString(matrixHTML:
            #"<span data-mx-spoiler>secret</span>"#
        )!
        // Foreground should be nearly transparent.
        let fg = attrs(result, at: 0)[.foregroundColor] as? NSColor
        #expect(fg != nil)
        // Background should be present.
        let bg = attrs(result, at: 0)[.backgroundColor] as? NSColor
        #expect(bg != nil)
    }

    // MARK: - Block Elements

    @Test func paragraphs() {
        let result = NSAttributedString(matrixHTML:"<p>hello</p><p>world</p>")!
        #expect(result.string == "hello\nworld")
    }

    @Test func divElements() {
        let result = NSAttributedString(matrixHTML:"<div>a</div><div>b</div>")!
        #expect(result.string == "a\nb")
    }

    @Test func blockquoteHasMarker() {
        let result = NSAttributedString(matrixHTML:
            "<blockquote><p>quoted</p></blockquote>"
        )!
        // The result should contain the marker placeholder followed by the text.
        #expect(result.string.contains("\u{FFFC}"))
        #expect(result.string.contains("quoted"))

        // The marker character should have the blockquoteMarker attribute.
        let markerAttrs = attrs(result, at: 0)
        #expect(markerAttrs[.blockquoteMarker] as? Bool == true)

        // The quoted text should have a paragraph style indenting it past the icon.
        let textIndex = (result.string as NSString).range(of: "quoted").location
        let style = attrs(result, at: textIndex)[.paragraphStyle] as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) > 0)
    }

    @Test func preformattedBlock() {
        let result = NSAttributedString(matrixHTML:"<pre>  code  \n  here  </pre>")!
        // Preformatted blocks should preserve whitespace.
        #expect(result.string.contains("  code  "))
        #expect(result.string.contains("  here  "))
        // Should use monospaced font.
        #expect(isMonospaced(result, at: 2))
        // Should have background color.
        let bg = attrs(result, at: 0)[.backgroundColor] as? NSColor
        #expect(bg != nil)
    }

    @Test func preContainingCode() {
        let result = NSAttributedString(matrixHTML:"<pre><code>x = 1</code></pre>")!
        #expect(result.string.contains("x = 1"))
        #expect(isMonospaced(result, at: 0))
    }

    @Test func headingFontSizes() {
        let baseSize = NSFont.systemFontSize

        let h1 = NSAttributedString(matrixHTML:"<h1>H1</h1>")!
        let h3 = NSAttributedString(matrixHTML:"<h3>H3</h3>")!
        let h6 = NSAttributedString(matrixHTML:"<h6>H6</h6>")!

        let h1Size = font(h1, at: 0)!.pointSize
        let h3Size = font(h3, at: 0)!.pointSize
        let h6Size = font(h6, at: 0)!.pointSize

        // H1 should be the largest, H6 should equal base size.
        #expect(h1Size > h3Size)
        #expect(h3Size > h6Size)
        #expect(h6Size == baseSize)

        // All headings should be bold.
        #expect(traits(h1, at: 0).contains(.bold))
        #expect(traits(h3, at: 0).contains(.bold))
        #expect(traits(h6, at: 0).contains(.bold))
    }

    @Test func headingHasParagraphStyle() {
        let result = NSAttributedString(matrixHTML:"<h1>Title</h1>")!
        let style = attrs(result, at: 0)[.paragraphStyle] as? NSParagraphStyle
        #expect(style != nil)
        #expect(style!.paragraphSpacingBefore > 0)
    }

    @Test func horizontalRule() {
        let result = NSAttributedString(matrixHTML:"<hr>")!
        // HR produces box-drawing characters.
        #expect(result.string.contains("\u{2500}"))
        // Should have separator color.
        let color = attrs(result, at: 0)[.foregroundColor] as? NSColor
        #expect(color != nil)
    }

    // MARK: - Lists

    @Test func unorderedList() {
        let result = NSAttributedString(matrixHTML:
            "<ul><li>alpha</li><li>beta</li></ul>"
        )!
        // Unordered list should use bullet markers.
        #expect(result.string.contains("\u{2022}"))
        #expect(result.string.contains("alpha"))
        #expect(result.string.contains("beta"))
    }

    @Test func orderedList() {
        let result = NSAttributedString(matrixHTML:
            "<ol><li>first</li><li>second</li></ol>"
        )!
        #expect(result.string.contains("1."))
        #expect(result.string.contains("2."))
        #expect(result.string.contains("first"))
        #expect(result.string.contains("second"))
    }

    @Test func orderedListCustomStart() {
        let result = NSAttributedString(matrixHTML:
            #"<ol start="5"><li>item</li></ol>"#
        )!
        #expect(result.string.contains("5."))
        #expect(result.string.contains("item"))
    }

    @Test func nestedLists() {
        let result = NSAttributedString(matrixHTML:"""
            <ul>
                <li>outer
                    <ul><li>inner</li></ul>
                </li>
            </ul>
            """)!
        #expect(result.string.contains("outer"))
        #expect(result.string.contains("inner"))
        // Should have different bullet types at different depths.
        // Depth 1 = \u{2022} (bullet), depth 2 = \u{25E6} (white bullet).
        #expect(result.string.contains("\u{2022}"))
        #expect(result.string.contains("\u{25E6}"))
    }

    @Test func orderedListCountsCorrectly() {
        let result = NSAttributedString(matrixHTML:
            "<ol><li>a</li><li>b</li><li>c</li></ol>"
        )!
        #expect(result.string.contains("1."))
        #expect(result.string.contains("2."))
        #expect(result.string.contains("3."))
    }

    // MARK: - Sanitization

    @Test func disallowedTagStrippedTextPreserved() {
        let result = NSAttributedString(matrixHTML:"<blink>text</blink>")!
        #expect(result.string == "text")
    }

    @Test func mxReplyRemoved() {
        let result = NSAttributedString(matrixHTML:
            "<mx-reply><blockquote>reply</blockquote></mx-reply>rest"
        )!
        #expect(result.string == "rest")
        #expect(!result.string.contains("reply"))
    }

    @Test func scriptTagStripped() {
        let result = NSAttributedString(matrixHTML:"<script>alert(1)</script>text")!
        // Script content should not appear.
        #expect(!result.string.contains("alert"))
        #expect(result.string.contains("text"))
    }

    @Test func nestedDisallowedTagsPreserveText() {
        let result = NSAttributedString(matrixHTML:
            "<div><blink><marquee>hello</marquee></blink></div>"
        )!
        #expect(result.string.contains("hello"))
    }

    // MARK: - Nesting

    @Test func boldAndItalicCombined() {
        let result = NSAttributedString(matrixHTML:"<b><i>text</i></b>")!
        #expect(result.string == "text")
        let fontTraits = traits(result, at: 0)
        #expect(fontTraits.contains(.bold))
        #expect(fontTraits.contains(.italic))
    }

    @Test func codeInsideBold() {
        let result = NSAttributedString(matrixHTML:"<b><code>text</code></b>")!
        #expect(result.string == "text")
        #expect(isMonospaced(result, at: 0))
        // Bold monospaced should have bold weight.
        let resolvedFont = font(result, at: 0)!
        #expect(resolvedFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func nestedBlockquotes() {
        let result = NSAttributedString(matrixHTML:
            "<blockquote><blockquote><p>deep</p></blockquote></blockquote>"
        )!
        #expect(result.string.contains("deep"))
        // Each nesting level contributes a marker placeholder.
        let markerCount = result.string.filter { $0 == "\u{FFFC}" }.count
        #expect(markerCount == 2)
    }

    @Test func boldInsideLink() {
        let result = NSAttributedString(matrixHTML:
            #"<a href="https://example.com"><b>bold link</b></a>"#
        )!
        #expect(result.string == "bold link")
        #expect(traits(result, at: 0).contains(.bold))
        let url = attrs(result, at: 0)[.link] as? URL
        #expect(url?.absoluteString == "https://example.com")
    }

    @Test func underlineInsideItalic() {
        let result = NSAttributedString(matrixHTML:"<i><u>text</u></i>")!
        #expect(result.string == "text")
        #expect(traits(result, at: 0).contains(.italic))
        let underline = attrs(result, at: 0)[.underlineStyle] as? Int
        #expect(underline == NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Edge Cases

    @Test func emptyStringReturnsEmpty() {
        let result = NSAttributedString(matrixHTML:"")
        // Empty string produces no content — result should be nil.
        if let result {
            #expect(result.length == 0)
        }
    }

    @Test func plainTextNoTags() {
        let result = NSAttributedString(matrixHTML:"hello world")!
        #expect(result.string == "hello world")
        // Should have a font attribute (system font).
        let resolvedFont = font(result, at: 0)
        #expect(resolvedFont != nil)
    }

    @Test func whitespaceOnlyBetweenBlocksSuppressed() {
        // The whitespace "\n  " between </p> and <p> should not appear in output.
        let result = NSAttributedString(matrixHTML:"<p>a</p>\n  <p>b</p>")!
        // Should not have extra whitespace between a and b.
        #expect(result.string == "a\nb")
    }

    @Test func malformedHTMLHandled() {
        // Unclosed tags should be handled gracefully.
        let result = NSAttributedString(matrixHTML:"<b>unclosed <i>italic")
        #expect(result != nil)
        #expect(result!.string.contains("unclosed"))
        #expect(result!.string.contains("italic"))
    }

    @Test func entityDecoding() {
        let result = NSAttributedString(matrixHTML:"&amp; &lt; &gt;")!
        #expect(result.string == "& < >")
    }

    @Test func multipleInlineFormattingResets() {
        // After a bold span, regular text should not be bold.
        let result = NSAttributedString(matrixHTML:"<b>bold</b> normal")!
        #expect(result.string == "bold normal")
        #expect(traits(result, at: 0).contains(.bold))
        // "normal" starts at index 5.
        #expect(!traits(result, at: 5).contains(.bold))
    }

    // MARK: - NSColor Hex Initializer

    @Test func hexWithHash() {
        let color = NSColor(matrixHex: "#ff0000")
        #expect(color != nil)
        let srgb = color!.usingColorSpace(.sRGB)!
        #expect(srgb.redComponent > 0.99)
        #expect(srgb.greenComponent < 0.01)
        #expect(srgb.blueComponent < 0.01)
    }

    @Test func hexWithoutHash() {
        let color = NSColor(matrixHex: "00ff00")
        #expect(color != nil)
        let srgb = color!.usingColorSpace(.sRGB)!
        #expect(srgb.greenComponent > 0.99)
    }

    @Test func invalidHexReturnsNil() {
        #expect(NSColor(matrixHex: "xyz") == nil)
        #expect(NSColor(matrixHex: "#12") == nil)
        #expect(NSColor(matrixHex: "") == nil)
    }

    @Test func hexBlue() {
        let color = NSColor(matrixHex: "#0000ff")!
        let srgb = color.usingColorSpace(.sRGB)!
        #expect(srgb.blueComponent > 0.99)
        #expect(srgb.redComponent < 0.01)
        #expect(srgb.greenComponent < 0.01)
    }

    // MARK: - Complex Real-World HTML

    @Test func matrixFormattedMessage() {
        // A realistic Matrix formatted_body with mixed inline formatting.
        let html = """
            <p>Hello <b>world</b>, this is <i>important</i> and \
            <a href="https://matrix.org">click here</a>.</p>
            """
        let result = NSAttributedString(matrixHTML:html)!
        #expect(result.string.contains("Hello"))
        #expect(result.string.contains("world"))
        #expect(result.string.contains("important"))
        #expect(result.string.contains("click here"))

        // "world" should be bold.
        let worldRange = (result.string as NSString).range(of: "world")
        #expect(traits(result, at: worldRange.location).contains(.bold))

        // "important" should be italic.
        let importantRange = (result.string as NSString).range(of: "important")
        #expect(traits(result, at: importantRange.location).contains(.italic))

        // "click here" should have a link.
        let linkRange = (result.string as NSString).range(of: "click here")
        let url = attrs(result, at: linkRange.location)[.link] as? URL
        #expect(url?.absoluteString == "https://matrix.org")
    }

    @Test func codeBlockFollowedByParagraph() {
        let result = NSAttributedString(matrixHTML:
            "<pre><code>let x = 1</code></pre><p>after</p>"
        )!
        #expect(result.string.contains("let x = 1"))
        #expect(result.string.contains("after"))

        // Code block text should be monospaced.
        let codeIndex = (result.string as NSString).range(of: "let").location
        #expect(isMonospaced(result, at: codeIndex))

        // "after" should not be monospaced.
        let afterIndex = (result.string as NSString).range(of: "after").location
        #expect(!isMonospaced(result, at: afterIndex))
    }

    // MARK: - Bare URL Detection in HTML

    @Test func bareURLInHTMLBecomesClickable() {
        let result = NSAttributedString(matrixHTML:
            "Check out https://www.getfedora.com for details"
        )!
        let urlRange = (result.string as NSString).range(of: "https://www.getfedora.com")
        let link = attrs(result, at: urlRange.location)[.link]
        #expect(link != nil)
        let url = link as? URL
        #expect(url?.absoluteString == "https://www.getfedora.com")
    }

    @Test func bareURLAlongsideMentionLink() {
        // Simulates a message with a Matrix mention <a> tag and a bare URL.
        let html = """
            <a href="https://matrix.to/#/@user:example.com">User</a> \
            check https://www.getfedora.com
            """
        let result = NSAttributedString(matrixHTML: html)!

        // The mention link should still work.
        let userRange = (result.string as NSString).range(of: "User")
        let mentionLink = attrs(result, at: userRange.location)[.link] as? URL
        #expect(mentionLink?.absoluteString == "https://matrix.to/#/@user:example.com")

        // The bare URL should also be clickable.
        let urlRange = (result.string as NSString).range(of: "https://www.getfedora.com")
        let bareLink = attrs(result, at: urlRange.location)[.link] as? URL
        #expect(bareLink?.absoluteString == "https://www.getfedora.com")
    }

    @Test func existingAnchorTagURLNotDuplicated() {
        // A URL already wrapped in <a> should not get a duplicate .link attribute.
        let html = """
            Visit <a href="https://example.com">https://example.com</a> today
            """
        let result = NSAttributedString(matrixHTML: html)!
        let urlRange = (result.string as NSString).range(of: "https://example.com")
        let link = attrs(result, at: urlRange.location)[.link] as? URL
        #expect(link?.absoluteString == "https://example.com")
    }

    @Test func multipleBareURLsInHTML() {
        let html = "See https://one.com and https://two.org for more"
        let result = NSAttributedString(matrixHTML: html)!

        let range1 = (result.string as NSString).range(of: "https://one.com")
        let link1 = attrs(result, at: range1.location)[.link] as? URL
        #expect(link1?.absoluteString == "https://one.com")

        let range2 = (result.string as NSString).range(of: "https://two.org")
        let link2 = attrs(result, at: range2.location)[.link] as? URL
        #expect(link2?.absoluteString == "https://two.org")
    }

    @Test func plainTextInHTMLWithoutURLsUnaffected() {
        let result = NSAttributedString(matrixHTML: "No links here, just text")!
        let firstCharAttrs = attrs(result, at: 0)
        #expect(firstCharAttrs[.link] == nil)
    }

    // MARK: - Combining Marks in Whitespace (Issue #146)

    @Test func combiningMarkAfterSpacePreserved() {
        // U+0E4B (Thai Mai Chattawa) is a combining mark. When it follows
        // a space, Swift groups them into a single Character whose
        // .isWhitespace returns true. The parser must not discard it.
        let html = "a \u{0E4B}b"
        let result = NSAttributedString(matrixHTML: html)!
        #expect(result.string.contains("\u{0E4B}"))
    }

    @Test func mentionLinkWithCombiningMarksInDisplayName() {
        // Simulates a Matrix mention whose display name contains combining
        // marks adjacent to spaces (e.g. "๋࣭ ⭑ username ๋࣭ ⭑").
        let displayName = "\u{0E4B}\u{08AD} \u{2B51} username \u{0E4B}\u{08AD} \u{2B51}"
        let html = """
            <a href="https://matrix.to/#/@user:example.com">\(displayName)</a>
            """
        let result = NSAttributedString(matrixHTML: html)
        #expect(result != nil, "Parser must not return nil for combining-mark display names")
        #expect(result?.string.contains("username") == true)
        // The link attribute should be set on the mention text.
        if let result {
            let link = attrs(result, at: 0)[.link] as? URL
            #expect(link?.absoluteString == "https://matrix.to/#/@user:example.com")
        }
    }

    @Test func mentionLinkWithCombiningMarksInContext() {
        // A mention with combining marks should not swallow surrounding text.
        let html = """
            Hello <a href="https://matrix.to/#/@u:e.com">\u{0E4B}\u{08AD} \u{2B51} name</a>!
            """
        let result = NSAttributedString(matrixHTML: html)!
        #expect(result.string.contains("Hello"))
        #expect(result.string.contains("name"))
        #expect(result.string.contains("!"))
        // The combining mark U+0E4B must not be discarded.
        #expect(result.string.unicodeScalars.contains(Unicode.Scalar(0x0E4B)!))
    }

    // MARK: - Tables

    @Test func simpleTable() {
        let html = """
            <table><tr><td>A</td><td>B</td></tr>\
            <tr><td>C</td><td>D</td></tr></table>
            """
        let result = NSAttributedString(matrixHTML: html)!
        // Cells within a row are separated by tabs, rows by newlines.
        #expect(result.string.contains("A\tB"))
        #expect(result.string.contains("C\tD"))
        #expect(result.string.contains("A\tB\nC\tD"))
    }

    @Test func tableWithHeaders() {
        let html = """
            <table><thead><tr><th>Name</th><th>Value</th></tr></thead>\
            <tbody><tr><td>a</td><td>1</td></tr></tbody></table>
            """
        let result = NSAttributedString(matrixHTML: html)!
        #expect(result.string.contains("Name\tValue"))
        #expect(result.string.contains("a\t1"))
        // Header cells should be bold.
        let nameIndex = (result.string as NSString).range(of: "Name").location
        #expect(traits(result, at: nameIndex).contains(.bold))
        // Data cells should not be bold.
        let dataRange = (result.string as NSString).range(of: "a\t1")
        #expect(!traits(result, at: dataRange.location).contains(.bold))
    }

    @Test func tableWithCaption() {
        let html = "<table><caption>Title</caption><tr><td>data</td></tr></table>"
        let result = NSAttributedString(matrixHTML: html)!
        #expect(result.string.contains("Title"))
        #expect(result.string.contains("data"))
        // Caption should be bold.
        let captionIndex = (result.string as NSString).range(of: "Title").location
        #expect(traits(result, at: captionIndex).contains(.bold))
    }

    @Test func singleCellTableNoTab() {
        let html = "<table><tr><td>only</td></tr></table>"
        let result = NSAttributedString(matrixHTML: html)!
        #expect(result.string.contains("only"))
        // No tab character when there is only one cell.
        #expect(!result.string.contains("\t"))
    }

    // MARK: - Paragraph Spacing

    @Test func paragraphsHaveSpacing() {
        let result = NSAttributedString(matrixHTML: "<p>hello</p><p>world</p>")!
        // String content unchanged.
        #expect(result.string == "hello\nworld")
        // The second paragraph ("world") should have paragraphSpacingBefore.
        let worldIndex = (result.string as NSString).range(of: "world").location
        let style = attrs(result, at: worldIndex)[.paragraphStyle] as? NSParagraphStyle
        #expect(style != nil)
        #expect(style!.paragraphSpacingBefore == 6)
    }

    @Test func firstParagraphHasSpacing() {
        // Even the first <p> gets the spacing attribute (it has no visual
        // effect at the top of the text view, but should be set consistently).
        let result = NSAttributedString(matrixHTML: "<p>only</p>")!
        let style = attrs(result, at: 0)[.paragraphStyle] as? NSParagraphStyle
        #expect(style != nil)
        #expect(style!.paragraphSpacingBefore == 6)
    }

    @Test func blockquoteHasSpacing() {
        let result = NSAttributedString(matrixHTML:
            "<p>before</p><blockquote><p>quoted</p></blockquote>"
        )!
        let quotedIndex = (result.string as NSString).range(of: "quoted").location
        let style = attrs(result, at: quotedIndex)[.paragraphStyle] as? NSParagraphStyle
        #expect(style != nil)
        #expect(style!.paragraphSpacingBefore == 6)
    }

    @Test func divElementsHaveSpacing() {
        let result = NSAttributedString(matrixHTML: "<div>a</div><div>b</div>")!
        #expect(result.string == "a\nb")
        let bIndex = (result.string as NSString).range(of: "b").location
        let style = attrs(result, at: bIndex)[.paragraphStyle] as? NSParagraphStyle
        #expect(style != nil)
        #expect(style!.paragraphSpacingBefore == 6)
    }

    // MARK: - Markdown Fallback

    @Test func markdownPlainTextUnchanged() {
        let result = NSAttributedString(matrixMarkdown: "hello")
        #expect(result.string == "hello")
    }

    @Test func markdownParagraphsJoinWithSingleNewline() {
        let result = NSAttributedString(matrixMarkdown: "# T\n\npara")
        #expect(result.string == "T\npara")
    }

    @Test func markdownSoftBreakPreservesNewline() {
        let result = NSAttributedString(matrixMarkdown: "line one\nline two")
        #expect(result.string == "line one\nline two")
    }

    @Test func markdownHeadingScaleAndSpacing() {
        let result = NSAttributedString(matrixMarkdown: "# Title")
        #expect(result.string == "Title")
        #expect(traits(result, at: 0).contains(.bold))
        let size = font(result, at: 0)?.pointSize ?? 0
        #expect(abs(size - MessageTextScale.baseFontSize * 1.5) < 0.5)
        let style = attrs(result, at: 0)[.paragraphStyle] as? NSParagraphStyle
        #expect(style?.paragraphSpacingBefore == 6)
    }

    @Test func markdownH3Scale() {
        let result = NSAttributedString(matrixMarkdown: "### Sub")
        #expect(result.string == "Sub")
        let size = font(result, at: 0)?.pointSize ?? 0
        #expect(abs(size - MessageTextScale.baseFontSize * 1.2) < 0.5)
    }

    @Test func markdownUnorderedList() {
        let result = NSAttributedString(matrixMarkdown: "- a\n- b")
        #expect(result.string == "• a\n• b")
        // List lines get an indent past the marker (offset 4 starts "• b";
        // offset 3 is the separator newline, which belongs to no block).
        let style = attrs(result, at: 4)[.paragraphStyle] as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) > 0)
    }

    @Test func markdownOrderedList() {
        let result = NSAttributedString(matrixMarkdown: "1. a\n2. b")
        #expect(result.string == "1. a\n2. b")
    }

    @Test func markdownOrderedListCustomStart() {
        let result = NSAttributedString(matrixMarkdown: "3. a\n4. b")
        #expect(result.string == "3. a\n4. b")
    }

    @Test func markdownBlockquoteHasMarker() {
        let result = NSAttributedString(matrixMarkdown: "> quoted")
        #expect(result.string.contains("quoted"))
        #expect(attrs(result, at: 0)[.blockquoteMarker] as? Bool == true)
    }

    @Test func markdownFencedCode() {
        let result = NSAttributedString(
            matrixMarkdown: "```swift\nlet x = 1\n```"
        )
        #expect(result.string.contains("let x = 1"))
        let codeIndex = (result.string as NSString).range(of: "let x = 1").location
        #expect(isMonospaced(result, at: codeIndex))
        #expect(attrs(result, at: codeIndex)[.backgroundColor] as? NSColor != nil)
    }

    @Test func markdownHorizontalRule() {
        let result = NSAttributedString(matrixMarkdown: "---")
        #expect(result.string == "────────")
        #expect(
            (attrs(result, at: 0)[.foregroundColor] as? NSColor)?.isEqual(
                NSColor.separatorColor
            ) == true
        )
    }

    @Test func markdownInlineFormatting() {
        let result = NSAttributedString(
            matrixMarkdown: "**bold** and *italic* and `code` and ~~strike~~"
        )
        #expect(result.string == "bold and italic and code and strike")
        #expect(traits(result, at: 0).contains(.bold))
        let italicIndex = (result.string as NSString).range(of: "italic").location
        #expect(traits(result, at: italicIndex).contains(.italic))
        let codeIndex = (result.string as NSString).range(of: "code").location
        #expect(isMonospaced(result, at: codeIndex))
        let strikeIndex = (result.string as NSString).range(of: "strike").location
        let strike = attrs(result, at: strikeIndex)[.strikethroughStyle] as? Int
        #expect(strike == NSUnderlineStyle.single.rawValue)
    }

    @Test func markdownLink() {
        let result = NSAttributedString(matrixMarkdown: "[Woo](https://kagi.com)")
        #expect(result.string == "Woo")
        #expect(
            attrs(result, at: 0)[.link] as? URL == URL(string: "https://kagi.com")
        )
    }

    @Test func markdownBareURLLinked() {
        let result = NSAttributedString(
            matrixMarkdown: "see https://kagi.com ok"
        )
        let urlIndex = (result.string as NSString)
            .range(of: "https://kagi.com").location
        #expect(
            attrs(result, at: urlIndex)[.link] as? URL
                == URL(string: "https://kagi.com")
        )
    }

    @Test func markdownInlineHTMLStaysLiteral() {
        // Spec-strict: without a formatted_body, inline HTML in the body is
        // literal text, while Markdown links still resolve.
        let result = NSAttributedString(
            matrixMarkdown: "<del>Yeah it looks like not</del> [Woo](https://kagi.com)"
        )
        #expect(result.string.contains("<del>"))
        let wooIndex = (result.string as NSString).range(of: "Woo").location
        #expect(wooIndex != NSNotFound)
        #expect(attrs(result, at: wooIndex)[.link] != nil)
    }

    // MARK: - Bare Matrix Identifiers

    /// Every character of a typed-out user ID must carry the full
    /// `matrix.to` link (later rendered as a mention pill). Previously
    /// `NSDataDetector` claimed just `matrix.org` as a URL first,
    /// fragmenting the identifier.
    private func expectFullIdentifierLink(
        _ str: NSAttributedString, identifier: String, url: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let nsString = str.string as NSString
        let idRange = nsString.range(of: identifier)
        #expect(idRange.location != NSNotFound, sourceLocation: sourceLocation)
        guard idRange.location != NSNotFound else { return }
        let expected = URL(string: url)
        for offset in idRange.location..<(idRange.location + idRange.length) {
            #expect(
                attrs(str, at: offset)[.link] as? URL == expected,
                "offset \(offset) should carry the full identifier link",
                sourceLocation: sourceLocation
            )
        }
    }

    @Test func markdownBareUserIdLinksFully() {
        let result = NSAttributedString(
            matrixMarkdown: "hi @exampleaccount:matrix.org"
        )
        expectFullIdentifierLink(
            result,
            identifier: "@exampleaccount:matrix.org",
            url: "https://matrix.to/#/@exampleaccount:matrix.org"
        )
    }

    @Test func markdownBareUserIdTrimsTrailingPeriod() {
        // Sentence-final punctuation is not part of the server name.
        let result = NSAttributedString(
            matrixMarkdown: "ping @bob:example.com."
        )
        expectFullIdentifierLink(
            result,
            identifier: "@bob:example.com",
            url: "https://matrix.to/#/@bob:example.com"
        )
        let dotIndex = (result.string as NSString).range(of: "@bob:example.com").location
            + "@bob:example.com".count
        #expect(attrs(result, at: dotIndex)[.link] == nil)
    }

    @Test func markdownBareUserIdWithPortLinksFully() {
        let result = NSAttributedString(
            matrixMarkdown: "ping @user:example.com:8448 ok"
        )
        expectFullIdentifierLink(
            result,
            identifier: "@user:example.com:8448",
            url: "https://matrix.to/#/@user:example.com:8448"
        )
    }

    @Test func markdownBareUserIdAlongsideBareURL() {
        // Both directions must coexist: the URL links as a URL, the full
        // user ID as a matrix.to link.
        let result = NSAttributedString(
            matrixMarkdown: "see https://kagi.com and @bob:example.com ok"
        )
        let urlIndex = (result.string as NSString)
            .range(of: "https://kagi.com").location
        #expect(
            attrs(result, at: urlIndex)[.link] as? URL
                == URL(string: "https://kagi.com")
        )
        expectFullIdentifierLink(
            result,
            identifier: "@bob:example.com",
            url: "https://matrix.to/#/@bob:example.com"
        )
    }

    @Test func markdownLinkTextNotRewrittenAsIdentifier() {
        // An explicit Markdown link keeps its own target.
        let result = NSAttributedString(
            matrixMarkdown: "[docs](https://example.com)"
        )
        #expect(
            attrs(result, at: 0)[.link] as? URL == URL(string: "https://example.com")
        )
    }

    @Test func htmlBareUserIdLinksFully() {
        // Plain-text user IDs in formatted_body HTML get the same treatment.
        let result = NSAttributedString(matrixHTML: "hi @exampleaccount:matrix.org")!
        expectFullIdentifierLink(
            result,
            identifier: "@exampleaccount:matrix.org",
            url: "https://matrix.to/#/@exampleaccount:matrix.org"
        )
    }
}
