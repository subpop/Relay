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
import Foundation
import RelayInterface

// MARK: - Parse Caches

extension MessageView {
    /// LRU cache for parsed HTML bodies. Shared across all `MessageView` instances.
    static let htmlCache = ParseCache<String, NSAttributedString?>(capacity: 128)

    /// LRU cache for parsed Markdown bodies. Shared across all `MessageView` instances.
    static let markdownCache = ParseCache<String, AttributedString>(capacity: 128)

    /// LRU cache for parsed emote HTML bodies. Shared across all `MessageView` instances.
    static let emoteHtmlCache = ParseCache<String, NSAttributedString?>(capacity: 64)

    /// LRU cache for parsed reply preview text. Shared across all `MessageView` instances.
    static let replyTextCache = ParseCache<String, String>(capacity: 128)

    static func parseMarkdown(_ raw: String) -> AttributedString {
        var result: AttributedString
        // swiftlint:disable:next identifier_name
        if let md = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            result = md
        } else {
            result = AttributedString(raw)
        }

        let plainString = String(result.characters)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return result
        }

        let matches = detector.matches(
            in: plainString,
            range: NSRange(plainString.startIndex..., in: plainString)
        )
        for match in matches {
            guard let urlRange = Range(match.range, in: plainString),
                  let attrRange = Range(urlRange, in: result) else { continue }
            if result[attrRange].link == nil {
                result[attrRange].link = match.url
            }
        }
        MatrixIdentifierLinker.linkify(&result)
        return result
    }

    /// Extracts clean display text from a reply's body, resolving HTML or Markdown
    /// formatting so that mention links and other markup are rendered as plain text.
    static func replyPreviewText(_ reply: TimelineMessage.ReplyDetail) -> String {
        // Prefer HTML path: parse the formatted body and extract the plain-text string.
        if let html = reply.formattedBody {
            return replyTextCache.value(forKey: html) {
                MatrixHTMLParser.parse(html)?.string ?? reply.body
            }
        }
        // Markdown fallback: parse inline markdown and extract the plain-text characters.
        return replyTextCache.value(forKey: reply.body) {
            if let md = try? AttributedString(
                markdown: reply.body,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                return String(md.characters)
            }
            return reply.body
        }
    }
}
