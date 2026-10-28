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

import Foundation
import ImageIO
import MatrixKit

/// Rules for adding images to the user's own sticker pack.
enum StickerPackEditing {
    /// The longest side of a sticker's intended display size, in points.
    /// Pack images should be about twice this in pixels, for sharp
    /// rendering on high-DPI displays.
    static let maxDisplaySide = 256

    /// Why a shortcode can't be used for a new sticker.
    enum ShortcodeProblem: Equatable {
        /// Outside the spec grammar (letters, digits, `-`, `_`; 1 to 100 bytes).
        case invalid
        /// Another sticker in the pack already uses it.
        case duplicate
    }

    /// The problem with using `shortcode` for a new sticker, or nil if it's usable.
    static func problem(with shortcode: String, existing: Set<String>) -> ShortcodeProblem? {
        if !ImagePack.isValidShortcode(shortcode) { return .invalid }
        if existing.contains(shortcode) { return .duplicate }
        return nil
    }

    /// A valid, unused shortcode derived from a file name: characters
    /// outside the grammar become `_`, and a numeric suffix resolves clashes.
    static func suggestedShortcode(fromFilename filename: String, avoiding existing: Set<String>) -> String {
        let stem = URL(filePath: filename).deletingPathExtension().lastPathComponent
        let mapped = stem.map { character -> Character in
            let allowed = character.isASCII && (character.isLetter || character.isNumber)
                || character == "-" || character == "_"
            return allowed ? character : "_"
        }
        var base = String(mapped)
        while base.contains("__") { base = base.replacing("__", with: "_") }
        while base.hasPrefix("_") { base.removeFirst() }
        base = String(base.prefix(ImagePack.maxShortcodeLength - 4))
        while base.hasSuffix("_") { base.removeLast() }
        if base.isEmpty { base = "sticker" }
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)_\(suffix)") { suffix += 1 }
        return "\(base)_\(suffix)"
    }

    /// The intended display size for an image of the given pixel size: the
    /// pixel size, scaled down to fit within `maxDisplaySide`.
    static func displaySize(pixelWidth: Int, pixelHeight: Int) -> (width: Int, height: Int) {
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDisplaySide else { return (pixelWidth, pixelHeight) }
        let scale = Double(maxDisplaySide) / Double(longest)
        return (
            max(1, Int((Double(pixelWidth) * scale).rounded())),
            max(1, Int((Double(pixelHeight) * scale).rounded()))
        )
    }

    /// The pixel dimensions of encoded image data, or nil if it isn't an image.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
