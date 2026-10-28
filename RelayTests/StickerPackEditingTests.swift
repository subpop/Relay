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
import MatrixKit
import Testing

@testable import Relay

/// Rules for adding images to the user's own sticker pack.
@Suite
struct StickerPackEditingTests {
    struct ShortcodeCase: Sendable {
        var filename: String
        var existing: Set<String>
        var expected: String
    }

    nonisolated static let suggestedShortcodes: [ShortcodeCase] = [
        ShortcodeCase(filename: "cat.png", existing: [], expected: "cat"),
        ShortcodeCase(filename: "Waving Cat (2).webp", existing: [], expected: "Waving_Cat_2"),
        ShortcodeCase(filename: "café.png", existing: [], expected: "caf"),
        ShortcodeCase(filename: "---.png", existing: [], expected: "---"),
        ShortcodeCase(filename: "!!!.png", existing: [], expected: "sticker"),
        ShortcodeCase(filename: "cat.png", existing: ["cat"], expected: "cat_2"),
        ShortcodeCase(filename: "cat.png", existing: ["cat", "cat_2"], expected: "cat_3"),
    ]

    @Test(arguments: suggestedShortcodes)
    func suggestsValidUnusedShortcodes(_ row: ShortcodeCase) {
        let shortcode = StickerPackEditing.suggestedShortcode(
            fromFilename: row.filename, avoiding: row.existing)
        #expect(shortcode == row.expected)
        #expect(ImagePack.isValidShortcode(shortcode))
        #expect(!row.existing.contains(shortcode))
    }

    @Test func longFilenamesStayWithinTheShortcodeLimit() {
        let existing = Set([String(repeating: "a", count: 96)])
        let shortcode = StickerPackEditing.suggestedShortcode(
            fromFilename: String(repeating: "a", count: 300) + ".png", avoiding: existing)
        #expect(ImagePack.isValidShortcode(shortcode))
        #expect(shortcode == String(repeating: "a", count: 96) + "_2")
    }

    @Test func reportsShortcodeProblems() {
        #expect(StickerPackEditing.problem(with: "cat", existing: []) == nil)
        #expect(StickerPackEditing.problem(with: "cat wave", existing: []) == .invalid)
        #expect(StickerPackEditing.problem(with: "", existing: []) == .invalid)
        #expect(StickerPackEditing.problem(with: "cat", existing: ["cat"]) == .duplicate)
    }

    struct SizeCase: Sendable {
        var pixels: (width: Int, height: Int)
        var expected: (width: Int, height: Int)
    }

    nonisolated static let displaySizes: [SizeCase] = [
        SizeCase(pixels: (128, 128), expected: (128, 128)),
        SizeCase(pixels: (256, 100), expected: (256, 100)),
        SizeCase(pixels: (512, 512), expected: (256, 256)),
        SizeCase(pixels: (1024, 512), expected: (256, 128)),
        SizeCase(pixels: (512, 1024), expected: (128, 256)),
        SizeCase(pixels: (4000, 1), expected: (256, 1)),
    ]

    @Test(arguments: displaySizes)
    func scalesDownToTheDisplayLimit(_ row: SizeCase) {
        let size = StickerPackEditing.displaySize(
            pixelWidth: row.pixels.width, pixelHeight: row.pixels.height)
        #expect(size.width == row.expected.width)
        #expect(size.height == row.expected.height)
    }

    @Test func readsPixelSizeFromImageData() throws {
        // A 1x1 PNG.
        let png = try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let size = try #require(StickerPackEditing.pixelSize(of: png))
        #expect(size.width == 1)
        #expect(size.height == 1)
        #expect(StickerPackEditing.pixelSize(of: Data("not an image".utf8)) == nil)
    }
}
