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

// MARK: - MessageBlockTests

struct MessageBlockTests {

    init() {
        UserDefaults.standard.removeObject(forKey: MessageTextScale.userDefaultsKey)
    }

    // MARK: - Helpers

    private func text(_ block: MessageBlock) -> String? {
        if case .richText(let string) = block { return string.string }
        return nil
    }

    private func code(_ block: MessageBlock) -> MessageCodeBlock? {
        if case .code(let code) = block { return code }
        return nil
    }

    private func table(_ block: MessageBlock) -> MessageTable? {
        if case .table(let table) = block { return table }
        return nil
    }

    // MARK: - HTML Code Blocks

    @Test func plainHTMLIsSingleRichTextBlock() {
        let blocks = MessageBlock.blocks(matrixHTML: "<p>hello</p><p>world</p>")
        #expect(blocks.count == 1)
        #expect(text(blocks[0]) == "hello\nworld")
    }

    @Test func emptyHTMLYieldsNoBlocks() {
        #expect(MessageBlock.blocks(matrixHTML: "").isEmpty)
    }

    @Test func preSplitsSurroundingProse() {
        let blocks = MessageBlock.blocks(
            matrixHTML: "<p>before</p>\n<pre><code>let x = 1\nlet y = 2\n</code></pre>\n<p>after</p>"
        )
        #expect(blocks.count == 3)
        #expect(text(blocks[0]) == "before")
        #expect(code(blocks[1])?.code == "let x = 1\nlet y = 2")
        #expect(text(blocks[2]) == "after")
    }

    @Test func codeLanguageComesFromClass() {
        let blocks = MessageBlock.blocks(
            matrixHTML: #"<pre><code class="language-swift">x</code></pre>"#
        )
        #expect(code(blocks[0])?.language == "swift")
    }

    @Test func codePreservesIndentationAndEntities() {
        let blocks = MessageBlock.blocks(
            matrixHTML: "<pre><code>if a &lt; b {\n    go()\n}</code></pre>"
        )
        #expect(code(blocks[0])?.code == "if a < b {\n    go()\n}")
    }

    @Test func preInsideBlockquoteStaysInline() {
        let blocks = MessageBlock.blocks(
            matrixHTML: "<blockquote><pre>quoted code</pre></blockquote>"
        )
        #expect(blocks.count == 1)
        #expect(text(blocks[0])?.contains("quoted code") == true)
    }

    @Test func emptyPreStaysInline() {
        let blocks = MessageBlock.blocks(matrixHTML: "<p>a</p><pre></pre><p>b</p>")
        #expect(blocks.count == 1)
    }

    @Test func unclosedPreRunsToEnd() {
        let blocks = MessageBlock.blocks(matrixHTML: "<pre>line one\nline two")
        #expect(code(blocks[0])?.code == "line one\nline two")
    }

    // MARK: - HTML Tables

    @Test func tableBecomesStructuredBlock() throws {
        let blocks = MessageBlock.blocks(matrixHTML: """
            <p>intro</p>\
            <table><thead><tr><th>Name</th><th>Qty</th></tr></thead>\
            <tbody><tr><td>Apple</td><td>3</td></tr><tr><td>Pear</td><td>12</td></tr></tbody></table>
            """)
        #expect(blocks.count == 2)
        let table = try #require(table(blocks[1]))
        #expect(table.rows.count == 3)
        #expect(table.rows[0].isHeader)
        #expect(!table.rows[1].isHeader)
        #expect(table.rows[0].cells.map(\.content.string) == ["Name", "Qty"])
        #expect(table.rows[2].cells.map(\.content.string) == ["Pear", "12"])
    }

    @Test func headerRowWithoutTheadIsDetected() throws {
        let blocks = MessageBlock.blocks(
            matrixHTML: "<table><tr><th>A</th></tr><tr><td>1</td></tr></table>"
        )
        let table = try #require(table(blocks[0]))
        #expect(table.rows.map(\.isHeader) == [true, false])
    }

    @Test func tableCellKeepsInlineFormatting() throws {
        let blocks = MessageBlock.blocks(
            matrixHTML: #"<table><tr><td><a href="https://example.com">link</a></td></tr></table>"#
        )
        let cell = try #require(table(blocks[0])?.rows[0].cells[0])
        #expect(cell.content.attribute(.link, at: 0, effectiveRange: nil) as? URL
            == URL(string: "https://example.com"))
    }

    @Test func tableAlignmentFromAttributeAndStyle() throws {
        let blocks = MessageBlock.blocks(matrixHTML: """
            <table><tr><td align="center">a</td>\
            <td style="text-align: right">b</td><td>c</td></tr></table>
            """)
        let cells = try #require(table(blocks[0])?.rows[0].cells)
        #expect(cells.map(\.alignment) == [.center, .trailing, .leading])
    }

    @Test func tableCaptionIsCaptured() throws {
        let blocks = MessageBlock.blocks(
            matrixHTML: "<table><caption>Totals</caption><tr><td>1</td></tr></table>"
        )
        let table = try #require(table(blocks[0]))
        #expect(table.caption?.string == "Totals")
        #expect(table.rows.count == 1)
    }

    @Test func emptyTableStaysInline() {
        let blocks = MessageBlock.blocks(matrixHTML: "<p>a</p><table></table>")
        #expect(blocks.count == 1)
    }

    // MARK: - Long Bodies

    @Test func shortBodyIsNotLong() {
        #expect(!MessageBlock.isLongBody("hello\nworld"))
    }

    @Test func manyLinesIsLong() {
        let lines = Array(repeating: "x", count: MessageBlock.longBodyLineCount)
        #expect(MessageBlock.isLongBody(lines.joined(separator: "\n")))
        #expect(!MessageBlock.isLongBody(lines.dropLast().joined(separator: "\n")))
    }

    @Test func manyBytesIsLong() {
        #expect(MessageBlock.isLongBody(String(repeating: "a", count: MessageBlock.longBodyByteCount)))
        #expect(!MessageBlock.isLongBody(String(repeating: "a", count: MessageBlock.longBodyByteCount - 1)))
    }

    // MARK: - Markdown Fences

    @Test func markdownWithoutFenceIsSingleBlock() {
        let blocks = MessageBlock.blocks(matrixMarkdown: "just **text**")
        #expect(blocks.count == 1)
        #expect(text(blocks[0]) == "just text")
    }

    @Test func markdownFenceSplitsProse() {
        let blocks = MessageBlock.blocks(
            matrixMarkdown: "before\n```swift\nlet x = 1\n\nlet y = 2\n```\nafter"
        )
        #expect(blocks.count == 3)
        #expect(text(blocks[0]) == "before")
        #expect(code(blocks[1])?.code == "let x = 1\n\nlet y = 2")
        #expect(code(blocks[1])?.language == "swift")
        #expect(text(blocks[2]) == "after")
    }

    @Test func markdownUnterminatedFenceRunsToEnd() {
        let blocks = MessageBlock.blocks(matrixMarkdown: "```\nopen\nforever")
        #expect(blocks.count == 1)
        #expect(code(blocks[0])?.code == "open\nforever")
    }

    @Test func markdownTildeFenceNeedsMatchingMarker() {
        let blocks = MessageBlock.blocks(matrixMarkdown: "~~~\na\n```\nb\n~~~")
        #expect(blocks.count == 1)
        #expect(code(blocks[0])?.code == "a\n```\nb")
    }

    @Test func markdownInlineTripleBacktickIsNotAFence() {
        let blocks = MessageBlock.blocks(matrixMarkdown: "use ```code``` inline")
        #expect(blocks.count == 1)
        #expect(text(blocks[0]) != nil)
    }

    @Test func markdownIndentedFenceBeyondThreeSpacesIsProse() {
        let blocks = MessageBlock.blocks(matrixMarkdown: "    ```\n    x\n    ```")
        #expect(blocks.allSatisfy { code($0) == nil })
    }
}
