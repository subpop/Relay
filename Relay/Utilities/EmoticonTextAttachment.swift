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
import SwiftUI

// MARK: - EmoticonTextAttachment

/// An `NSTextAttachment` that draws a custom emoticon inline: the image of an
/// `<img data-mx-emoticon>` element in a message's `formatted_body`.
///
/// The image is not known when the message is parsed, so the attachment starts
/// with a blank square and the text view fills it in once the media has loaded.
/// The square is fixed up front, so a loaded image only redraws and never
/// changes the layout. Like PillTextAttachment it carries a bitmap in
/// `image`, which draws the same in every TextKit 2 context.
nonisolated final class EmoticonTextAttachment: NSTextAttachment, @unchecked Sendable {

    /// The emoticon's height and width as a multiple of the font size.
    private static let sizeInEms: CGFloat = 1.5

    /// The `mxc://` URI of the image.
    let mxcURI: String

    /// The `alt` text: the image's description, or its shortcode.
    let altText: String?

    /// The `title` text: the image's shortcode.
    let shortcode: String?

    /// Whether the image has been drawn, or its load has failed.
    private(set) var isResolved = false

    private let side: CGFloat

    init(mxcURI: String, altText: String?, shortcode: String?, font: NSFont) {
        self.mxcURI = mxcURI
        self.altText = altText
        self.shortcode = shortcode
        self.side = (font.pointSize * Self.sizeInEms).rounded()
        super.init(data: nil, ofType: nil)
        attachmentCell = nil
        // Centered on the cap height, so the image sits in the middle of the
        // text's visual line.
        bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        if let cached = EmoticonImageCache.image(for: mxcURI) {
            setLoaded(cached)
        } else {
            image = NSImage(size: NSSize(width: side, height: side))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EmoticonTextAttachment does not support NSCoding")
    }

    /// The text that stands in for the emoticon where only text is shown: its
    /// `alt`, else its shortcode between colons.
    var plainText: String {
        if let altText, !altText.isEmpty { return altText }
        if let shortcode, !shortcode.isEmpty { return ":\(shortcode):" }
        return ":emoticon:"
    }

    /// Draws the loaded image, scaled to fit the square.
    func setLoaded(_ source: NSImage) {
        image = Self.fitted(source, side: side)
        isResolved = true
    }

    /// Draws a neutral placeholder after the image could not be loaded.
    func setFailed() {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor])
        let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image = symbol.map { Self.fitted($0, side: side * 0.7, canvas: side) }
            ?? NSImage(size: NSSize(width: side, height: side))
        isResolved = true
    }

    /// `source` scaled to fit and centered in a square canvas, so the
    /// attachment keeps its fixed bounds whatever the image's aspect ratio.
    private static func fitted(_ source: NSImage, side: CGFloat, canvas: CGFloat? = nil) -> NSImage {
        let canvas = canvas ?? side
        let size = source.size
        guard size.width > 0, size.height > 0 else {
            return NSImage(size: NSSize(width: canvas, height: canvas))
        }
        let scale = min(side / size.width, side / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        return NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            source.draw(
                in: NSRect(
                    x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2,
                    width: drawn.width, height: drawn.height))
            return true
        }
    }
}

// MARK: - Image Cache

/// Decoded emoticon images by `mxc://` URI, so an emoticon seen before draws
/// the moment its message is laid out instead of after a fetch.
nonisolated enum EmoticonImageCache {
    private nonisolated(unsafe) static let storage = NSCache<NSString, NSImage>()

    static func image(for mxcURI: String) -> NSImage? {
        storage.object(forKey: mxcURI as NSString)
    }

    static func store(_ image: NSImage, for mxcURI: String) {
        storage.setObject(image, forKey: mxcURI as NSString)
    }
}

// MARK: - Image Loading

/// Fetches the image behind an emoticon's `mxc://` URI. Supplied through the
/// environment because only the app's client can download media.
struct EmoticonImageLoader: Sendable {
    var load: (@MainActor @Sendable (String) async -> NSImage?)?

    /// Has no way to load, so emoticons keep their blank placeholder.
    static let none = EmoticonImageLoader(load: nil)
}

private struct EmoticonImageLoaderKey: EnvironmentKey {
    static let defaultValue = EmoticonImageLoader.none
}

extension EnvironmentValues {
    /// The loader that emoticons in message text use to fetch their images.
    var emoticonImageLoader: EmoticonImageLoader {
        get { self[EmoticonImageLoaderKey.self] }
        set { self[EmoticonImageLoaderKey.self] = newValue }
    }
}

// MARK: - Attributed String Helpers

extension NSAttributedString {
    /// Every emoticon attachment in the string, in order.
    var emoticonAttachments: [EmoticonTextAttachment] {
        var found: [EmoticonTextAttachment] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, _, _ in
            if let emoticon = value as? EmoticonTextAttachment { found.append(emoticon) }
        }
        return found
    }

    /// Whether the string contains a custom emoticon.
    var containsEmoticons: Bool { !emoticonAttachments.isEmpty }

    /// The string with each emoticon replaced by its alt text, for previews
    /// and other places that show text only. Other attachments are untouched.
    var plainTextReplacingEmoticons: String {
        let text = NSMutableString(string: string)
        var replacements: [(NSRange, String)] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, _ in
            if let emoticon = value as? EmoticonTextAttachment {
                replacements.append((range, emoticon.plainText))
            }
        }
        for (range, replacement) in replacements.reversed() {
            text.replaceCharacters(in: range, with: replacement)
        }
        return text as String
    }
}
