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
import MatrixKit
import Testing

@testable import Relay

/// Custom emoticons (`<img data-mx-emoticon>`) in formatted message bodies.
@Suite
struct EmoticonRenderingTests {
    nonisolated private static let cat = #"<img data-mx-emoticon src="mxc://matrix.org/cat" alt="a cat" title="cat_wave" height="32">"#

    struct ParseCase: Sendable {
        var id: String
        var html: String
        var plainText: String
        var emoticonCount: Int
    }

    nonisolated static let parseCases: [ParseCase] = [
        ParseCase(
            id: "inline in text", html: "<p>hi \(cat) there</p>",
            plainText: "hi a cat there", emoticonCount: 1),
        ParseCase(
            id: "alone in a paragraph", html: "<p>\(cat)</p>",
            plainText: "a cat", emoticonCount: 1),
        ParseCase(
            id: "self-closing", html: #"<img data-mx-emoticon src="mxc://x/y" alt="cat" />"#,
            plainText: "cat", emoticonCount: 1),
        ParseCase(
            id: "marker with a value", html: #"<img data-mx-emoticon="" src="mxc://x/y" alt="cat">"#,
            plainText: "cat", emoticonCount: 1),
        ParseCase(
            id: "two in a row", html: "\(cat)\(cat)",
            plainText: "a cata cat", emoticonCount: 2),
        ParseCase(
            id: "no alt falls back to the shortcode",
            html: #"<img data-mx-emoticon src="mxc://x/y" title="cat_wave">"#,
            plainText: ":cat_wave:", emoticonCount: 1),
        ParseCase(
            id: "no alt or title", html: #"<img data-mx-emoticon src="mxc://x/y">"#,
            plainText: ":emoticon:", emoticonCount: 1),
        ParseCase(
            id: "an image without the marker is not an emoticon",
            html: #"<p>hi <img src="mxc://x/y" alt="cat"> there</p>"#,
            plainText: "hi  there", emoticonCount: 0),
        ParseCase(
            id: "only mxc sources load",
            html: #"<p>hi <img data-mx-emoticon src="https://example.org/cat.png" alt="cat"> there</p>"#,
            plainText: "hi  there", emoticonCount: 0),
        ParseCase(
            id: "a source that is not a content URI",
            html: #"<p>hi <img data-mx-emoticon src="mxc://" alt="cat"> there</p>"#,
            plainText: "hi  there", emoticonCount: 0),
        ParseCase(
            id: "no source", html: #"<p>hi <img data-mx-emoticon alt="cat"> there</p>"#,
            plainText: "hi  there", emoticonCount: 0),
    ]

    @Test(arguments: parseCases)
    func parsesEmoticons(_ row: ParseCase) throws {
        let parsed = try #require(NSAttributedString(matrixHTML: row.html))
        #expect(parsed.emoticonAttachments.count == row.emoticonCount)
        #expect(parsed.plainTextReplacingEmoticons == row.plainText)
    }

    @Test func aMessageOfOnlyAnEmoticonStillParses() {
        #expect(NSAttributedString(matrixHTML: "<p>\(Self.cat)</p>") != nil)
    }

    @Test func carriesTheImageDetails() throws {
        let parsed = try #require(NSAttributedString(matrixHTML: "<p>\(Self.cat)</p>"))
        let emoticon = try #require(parsed.emoticonAttachments.first)
        #expect(emoticon.mxcURI == "mxc://matrix.org/cat")
        #expect(emoticon.altText == "a cat")
        #expect(emoticon.shortcode == "cat_wave")
        // The shortcode is the tooltip.
        let index = try #require(
            (parsed.string as NSString).range(of: "\u{FFFC}").location as Int?)
        #expect(parsed.attribute(.toolTip, at: index, effectiveRange: nil) as? String == "cat_wave")
    }

    @Test func keepsTheSurroundingLink() throws {
        let html = #"<a href="https://example.org">see \#(Self.cat)</a>"#
        let parsed = try #require(NSAttributedString(matrixHTML: html))
        let index = (parsed.string as NSString).range(of: "\u{FFFC}").location
        #expect(parsed.attribute(.link, at: index, effectiveRange: nil) != nil)
    }

    @Test func sizesWithTheFont() {
        let small = EmoticonTextAttachment(
            mxcURI: "mxc://x/size", altText: nil, shortcode: nil, font: .systemFont(ofSize: 10))
        let large = EmoticonTextAttachment(
            mxcURI: "mxc://x/size", altText: nil, shortcode: nil, font: .systemFont(ofSize: 20))
        #expect(small.bounds.width == 15)
        #expect(large.bounds.width == 30)
        #expect(small.bounds.width == small.bounds.height)
    }

    @Test func startsBlankAndResolvesWhenLoadedOrFailed() {
        let loaded = EmoticonTextAttachment(
            mxcURI: "mxc://x/loaded-\(UUID())", altText: nil, shortcode: nil, font: .systemFont(ofSize: 13))
        #expect(!loaded.isResolved)
        loaded.setLoaded(NSImage(size: NSSize(width: 64, height: 32)))
        #expect(loaded.isResolved)
        #expect(loaded.image?.size == NSSize(width: loaded.bounds.width, height: loaded.bounds.height))

        let failed = EmoticonTextAttachment(
            mxcURI: "mxc://x/failed-\(UUID())", altText: nil, shortcode: nil, font: .systemFont(ofSize: 13))
        failed.setFailed()
        #expect(failed.isResolved)
    }

    @Test func aCachedImageDrawsImmediately() {
        let uri = "mxc://x/cached-\(UUID())"
        EmoticonImageCache.store(NSImage(size: NSSize(width: 8, height: 8)), for: uri)
        let emoticon = EmoticonTextAttachment(
            mxcURI: uri, altText: nil, shortcode: nil, font: .systemFont(ofSize: 13))
        #expect(emoticon.isResolved)
    }

    @Test func anEmoticonKeepsAMessageFromBeingBigEmoji() {
        // The plain body is emoji-only, but large emoji would draw only the body.
        let html = "<p>👋\(Self.cat)</p>"
        #expect(!isBigEmojiMessage(body: "👋", formattedBody: html))
        #expect(isBigEmojiMessage(body: "👋", formattedBody: "<p>👋</p>"))
    }

    @Test func previewsShowTheAltText() {
        let reply = ResolvedReply(
            eventID: EventId(unchecked: "$e:x"), senderID: UserId(unchecked: "@a:x"),
            senderDisplayName: nil, body: ":cat_wave:",
            formattedBody: "<p>look \(Self.cat) \(UUID())</p>", imageURL: nil)
        #expect(ReplyPreviewBubble.replyPreviewText(reply).hasPrefix("look a cat"))
    }

    // MARK: - Drawing

    /// How many opaque red pixels the view draws.
    @MainActor
    private func redPixels(in view: NSTextView) throws -> Int {
        view.layoutSubtreeIfNeeded()
        if let layout = view.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.5, color.redComponent > 0.8,
                    color.greenComponent < 0.2, color.blueComponent < 0.2
                {
                    count += 1
                }
            }
        }
        return count
    }

    private static func solidImage(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        return image
    }

    @MainActor
    @Test func aLoadedEmoticonRepaintsTheTextView() async throws {
        let attachment = EmoticonTextAttachment(
            mxcURI: "mxc://x/repaint-\(UUID())", altText: "red", shortcode: nil,
            font: .systemFont(ofSize: 13))
        let view = MessageTextContent(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.isEditable = false
        view.drawsBackground = false
        view.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))
        view.emoticonImageLoader = EmoticonImageLoader { _ in Self.solidImage(.red) }

        let before = try redPixels(in: view)
        let loading = try #require(view.loadPendingEmoticons())
        await loading.value
        let after = try redPixels(in: view)

        #expect(attachment.isResolved)
        #expect(before == 0)
        #expect(after > 0)
    }

    @MainActor
    @Test func emoticonsWithoutALoaderStayBlank() throws {
        let attachment = EmoticonTextAttachment(
            mxcURI: "mxc://x/blank-\(UUID())", altText: nil, shortcode: nil,
            font: .systemFont(ofSize: 13))
        let view = MessageTextContent(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))
        #expect(view.loadPendingEmoticons() == nil)
        #expect(!attachment.isResolved)
    }

    @MainActor
    @Test func aFailedLoadResolvesWithAPlaceholder() async throws {
        let attachment = EmoticonTextAttachment(
            mxcURI: "mxc://x/fail-\(UUID())", altText: nil, shortcode: nil,
            font: .systemFont(ofSize: 13))
        let view = MessageTextContent(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))
        view.emoticonImageLoader = EmoticonImageLoader { _ in nil }
        await view.loadPendingEmoticons()?.value
        #expect(attachment.isResolved)
        #expect(EmoticonImageCache.image(for: attachment.mxcURI) == nil)
    }
}
