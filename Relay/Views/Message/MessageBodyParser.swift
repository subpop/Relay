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

// MARK: - Parse Caches (MessageBubbleContent)

extension MessageBubbleContent {
    /// LRU cache for parsed HTML bodies. Shared across all `MessageBubbleContent` instances.
    static let htmlCache = ParseCache<String, NSAttributedString?>(capacity: 128)

    /// LRU cache for parsed Markdown bodies. Shared across all `MessageBubbleContent` instances.
    static let markdownCache = ParseCache<String, NSAttributedString>(capacity: 128)

    /// LRU cache for parsed emote HTML bodies. Shared across all `MessageBubbleContent` instances.
    static let emoteHtmlCache = ParseCache<String, NSAttributedString?>(capacity: 64)

    /// Drops every message parse cache.
    ///
    /// Call when a global change must force every row to re-render from
    /// scratch — a text-zoom step, where the cached attributed strings were
    /// built at the old font size. A window resize does *not* need this: the
    /// text container's stale-width problem is handled separately, by
    /// ``MessageTextView``'s size-cache generation counter. Because the
    /// caches key by content, the returned attributed string is a *new*
    /// instance, which makes ``MessageTextView``'s `updateNSView` re-resolve
    /// and re-sync its container to the current width instead of
    /// early-returning on an unchanged instance.
    @MainActor
    static func invalidateParseCaches() {
        htmlCache.removeAll()
        markdownCache.removeAll()
        emoteHtmlCache.removeAll()
        ReplyPreviewBubble.replyTextCache.removeAll()
    }
}

// MARK: - Parse Caches (ReplyPreviewBubble)

extension ReplyPreviewBubble {
    /// LRU cache for parsed reply preview text. Shared across all `ReplyPreviewBubble` instances.
    static let replyTextCache = ParseCache<String, String>(capacity: 128)

    /// Extracts clean display text from a reply's body, resolving HTML or Markdown
    /// formatting so that mention links and other markup are rendered as plain text.
    static func replyPreviewText(_ reply: TimelineMessage.ReplyDetail) -> String {
        // Prefer HTML path: parse the formatted body and extract the plain-text string.
        if let html = reply.formattedBody {
            return replyTextCache.value(forKey: html) {
                NSAttributedString(matrixHTML: html)?.string ?? reply.body
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
