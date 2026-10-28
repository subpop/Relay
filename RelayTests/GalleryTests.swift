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

/// Gallery messages (MSC4274): item rendering data and the send decision.
@Suite @MainActor
struct GalleryTests {

    @Test func plainItemBuildsADownload() {
        let item = MediaItem(
            galleryItem: GalleryItem(
                itemtype: .image, body: "a.png", filename: "a.png",
                url: "mxc://x/a", info: MediaInfo(mimeType: "image/png", size: 10)))
        #expect(item.download?.mxcURL == "mxc://x/a")
        #expect(item.download?.filename == "a.png")
        #expect(item.download?.mimetype == "image/png")
        #expect(item.caption == nil)
    }

    @Test func itemBodyDifferingFromFilenameIsACaption() {
        let item = MediaItem(
            galleryItem: GalleryItem(
                itemtype: .image, body: "Sunset", filename: "a.png", url: "mxc://x/a"))
        #expect(item.caption == "Sunset")
    }

    @Test func itemWithoutASourceHasNoDownload() {
        let item = MediaItem(galleryItem: GalleryItem(itemtype: .image, filename: "a.png"))
        #expect(item.download == nil)
        #expect(item.fallbackName == "a.png")
    }

    @Test func galleryRoomPreviewCountsItems() {
        let content = MessageContent(
            msgtype: .gallery, body: "x",
            itemtypes: [GalleryItem(itemtype: .image), GalleryItem(itemtype: .file)])
        #expect(RoomRowData.preview(for: content) == "Sent 2 attachments")
    }

    @Test func deckPositionsAreRelativeToTheTopCard() {
        var deck = GalleryDeck()
        #expect(deck.drawOrder(count: 5) == [2, 1, 0])
        deck.advance(count: 5)
        #expect(deck.position(of: 1, count: 5) == 0)
        #expect(deck.position(of: 0, count: 5) == 4)
        #expect(deck.drawOrder(count: 5) == [3, 2, 1])
        #expect(deck.number(count: 5) == 2)
    }

    @Test func deckCyclingWraps() {
        var deck = GalleryDeck()
        deck.retreat(count: 3)
        #expect(deck.number(count: 3) == 3)
        deck.advance(count: 3)
        #expect(deck.number(count: 3) == 1)
    }

    @Test func deckMovesByStepsInEitherDirection() {
        let deck = GalleryDeck()
        #expect(deck.moved(by: 2, count: 5).number(count: 5) == 3)
        #expect(deck.moved(by: -1, count: 5).number(count: 5) == 5)
        #expect(deck.moved(by: 7, count: 5).number(count: 5) == 3)
        #expect(deck.moved(by: 3, count: 0) == deck)
    }

    @Test func smallDecksDrawEveryCard() {
        #expect(GalleryDeck().drawOrder(count: 2) == [1, 0])
        #expect(GalleryDeck().drawOrder(count: 0) == [])
    }

    @Test func galleryNeedsTheLabsOptionAndTwoAttachments() {
        #expect(
            ComposeViewModel.galleryCaption(text: "hi", attachmentCount: 2, galleriesEnabled: false)
                == nil)
        #expect(
            ComposeViewModel.galleryCaption(text: "hi", attachmentCount: 1, galleriesEnabled: true)
                == nil)
        #expect(
            ComposeViewModel.galleryCaption(text: "hi", attachmentCount: 2, galleriesEnabled: true)
                == "hi")
    }

    @Test func galleryWithoutTextUsesTheSummaryCaption() {
        #expect(
            ComposeViewModel.galleryCaption(text: "", attachmentCount: 3, galleriesEnabled: true)
                == "3 attachments")
    }
}
