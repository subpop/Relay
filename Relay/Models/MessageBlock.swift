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

/// A top-level piece of a parsed message body.
///
/// Inline-formatted prose stays a single `NSAttributedString` rendered by
/// ``MessageTextView``. Content that an attributed string can't lay out
/// well on its own (code blocks that scroll horizontally, tables with
/// aligned columns) becomes its own block, rendered by ``MessageBlocksView``.
enum MessageBlock {
    case richText(NSAttributedString)
    case code(MessageCodeBlock)
    case table(MessageTable)
}

/// A fenced or `<pre>` code block.
struct MessageCodeBlock {
    let code: String

    /// The language from a `language-*` class or Markdown info string, if any.
    let language: String?
}

/// A `<table>` with inline-formatted cells.
struct MessageTable {
    enum Alignment {
        case leading, center, trailing
    }

    struct Cell {
        let content: NSAttributedString
        let alignment: Alignment
    }

    struct Row {
        let cells: [Cell]
        let isHeader: Bool
    }

    let caption: NSAttributedString?
    let rows: [Row]
}

// MARK: - Long Messages

extension MessageBlock {
    /// Bodies at least this many UTF-8 bytes long are collapsed in the timeline.
    static let longBodyByteCount = 1_500

    /// Bodies with at least this many lines are collapsed in the timeline.
    static let longBodyLineCount = 12

    /// Whether a message body is long enough to collapse behind "Show More".
    ///
    /// Decided from the raw body rather than measured layout so the
    /// timeline row height is stable on first render.
    static func isLongBody(_ body: String) -> Bool {
        let bytes = body.utf8
        if bytes.count >= longBodyByteCount { return true }
        let newline = UInt8(ascii: "\n")
        return bytes.lazy.filter { $0 == newline }.prefix(longBodyLineCount - 1).count
            >= longBodyLineCount - 1
    }
}

// MARK: - Markdown

extension MessageBlock {
    /// Splits a plain-text message `body` into blocks, lifting fenced code
    /// (``` or ~~~) out of the surrounding Markdown. Prose between fences is
    /// parsed with ``NSAttributedString/init(matrixMarkdown:)``.
    static func blocks(matrixMarkdown body: String) -> [MessageBlock] {
        guard body.contains("```") || body.contains("~~~") else {
            return [.richText(NSAttributedString(matrixMarkdown: body))]
        }

        var blocks: [MessageBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var fence: Fence?

        func flushProse() {
            let text = prose.joined(separator: "\n")
            prose.removeAll()
            guard !text.allSatisfy(\.isWhitespace) else { return }
            blocks.append(.richText(NSAttributedString(matrixMarkdown: text)))
        }

        func flushCode(language: String?) {
            let text = code.joined(separator: "\n")
            code.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.code(MessageCodeBlock(code: text, language: language)))
        }

        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let open = fence {
                if open.isClosed(by: line) {
                    flushCode(language: open.language)
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if let open = Fence(opening: line) {
                flushProse()
                fence = open
            } else {
                prose.append(line)
            }
        }
        // An unterminated fence runs to the end of the message.
        if let open = fence { flushCode(language: open.language) }
        flushProse()

        return blocks.isEmpty ? [.richText(NSAttributedString(matrixMarkdown: body))] : blocks
    }

    /// A CommonMark code fence: three or more backticks or tildes, indented
    /// at most three spaces.
    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?

        init?(opening line: Substring) {
            guard let (marker, length, rest) = Self.scan(line), length >= 3 else { return nil }
            let info = rest.trimmingCharacters(in: .whitespaces)
            // A backtick fence's info string can't contain backticks, or
            // "```code```" on one line would open a fence.
            if marker == "`", info.contains("`") { return nil }
            self.marker = marker
            self.length = length
            self.language = info.split(separator: " ").first.map(String.init)
        }

        func isClosed(by line: Substring) -> Bool {
            guard let (marker, length, rest) = Self.scan(line) else { return false }
            return marker == self.marker && length >= self.length
                && rest.allSatisfy(\.isWhitespace)
        }

        /// Splits a line into its fence marker, run length, and remainder.
        private static func scan(_ line: Substring) -> (Character, Int, Substring)? {
            let indent = line.prefix { $0 == " " }
            guard indent.count <= 3 else { return nil }
            let body = line.dropFirst(indent.count)
            guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
            let run = body.prefix { $0 == marker }
            return (marker, run.count, body.dropFirst(run.count))
        }
    }
}
