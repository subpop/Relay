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

/// Which packs and stickers the sticker picker offers.
@Suite
struct StickerPickerViewModelTests {
    private static let room = RoomId(unchecked: "!room:matrix.org")

    private static func pack(
        _ stateKey: String, shortcodes: [String] = ["wave"], usage: [ImagePackUsage]? = nil,
        displayName: String? = nil
    ) -> ImagePack {
        ImagePack(
            roomId: room, stateKey: stateKey, source: .room,
            content: ImagePackContent(
                images: Dictionary(
                    uniqueKeysWithValues: shortcodes.map {
                        ($0, ImagePackImage(url: "mxc://matrix.org/\($0)"))
                    }),
                pack: ImagePackMeta(usage: usage)),
            displayName: displayName)
    }

    @Test func offersPacksForStickersOnly() {
        let sections = StickerPickerViewModel.sections(from: [
            Self.pack("stickers", usage: [.sticker]),
            Self.pack("emoticons", usage: [.emoticon]),
            Self.pack("both", usage: [.emoticon, .sticker]),
            Self.pack("unspecified"),
        ])
        #expect(sections.map(\.title) == ["stickers", "both", "unspecified"])
    }

    @Test func keepsPackPriorityOrder() {
        let sections = StickerPickerViewModel.sections(from: [
            Self.pack("b"), Self.pack("a"), Self.pack("c"),
        ])
        #expect(sections.map(\.title) == ["b", "a", "c"])
    }

    @Test func omitsEmptyPacks() {
        let sections = StickerPickerViewModel.sections(from: [
            Self.pack("empty", shortcodes: []), Self.pack("full"),
        ])
        #expect(sections.map(\.title) == ["full"])
    }

    @Test func titlesPacksByNameThenStateKey() {
        let sections = StickerPickerViewModel.sections(from: [
            Self.pack("cats", displayName: "Cats"),
            Self.pack("dogs", displayName: ""),
            Self.pack("", displayName: nil),
        ])
        #expect(sections.map(\.title).prefix(2) == ["Cats", "dogs"])
        #expect(sections[2].title == "Stickers")
    }

    @Test func sortsStickersNaturallyByShortcode() {
        let entries = StickerPickerViewModel.entries(
            of: Self.pack("p", shortcodes: ["cat10", "cat2", "Cat1"]).content)
        #expect(entries.map(\.shortcode) == ["Cat1", "cat2", "cat10"])
    }
}
