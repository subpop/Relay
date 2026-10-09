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

import MatrixKit
import Testing

@testable import Relay

// MARK: - BrowseRoomsPaginationTests

/// Directory pagination termination: some servers keep returning a
/// continuation token (or repeat rooms) instead of ending the result
/// set, which used to loop pagination requests and duplicate rows.
struct BrowseRoomsPaginationTests {
    private func entry(_ roomId: String) -> PublicRoomEntry {
        PublicRoomEntry(roomId: RoomId(unchecked: roomId))
    }

    private func page(
        rooms: [PublicRoomEntry] = [PublicRoomEntry(roomId: RoomId(unchecked: "!a:example.com"))],
        nextBatch: String? = "t0"
    ) -> BrowseRoomsViewModel.ServerPage {
        BrowseRoomsViewModel.ServerPage(
            serverName: "example.com", isHome: true,
            rooms: rooms, nextBatch: nextBatch)
    }

    @Test("Nil token ends pagination")
    func nilTokenEndsPagination() {
        var page = self.page()
        BrowseRoomsViewModel.applyPage(
            rooms: [entry("!b:example.com")], nextBatch: nil,
            sentBatch: "t0", to: &page)
        #expect(page.isAtEnd)
        #expect(page.rooms.count == 2)
    }

    @Test("Empty chunk with a token ends pagination")
    func emptyChunkEndsPagination() {
        var page = self.page()
        BrowseRoomsViewModel.applyPage(
            rooms: [], nextBatch: "t1", sentBatch: "t0", to: &page)
        #expect(page.isAtEnd)
        #expect(page.rooms.count == 1)
    }

    @Test("Echoed token ends pagination")
    func echoedTokenEndsPagination() {
        var page = self.page()
        BrowseRoomsViewModel.applyPage(
            rooms: [entry("!b:example.com")], nextBatch: "t0",
            sentBatch: "t0", to: &page)
        #expect(page.isAtEnd)
        #expect(page.rooms.count == 2)
    }

    @Test("All-duplicate chunk ends pagination without duplicating rows")
    func duplicateChunkEndsPagination() {
        var page = self.page()
        BrowseRoomsViewModel.applyPage(
            rooms: [entry("!a:example.com")], nextBatch: "t1",
            sentBatch: "t0", to: &page)
        #expect(page.isAtEnd)
        #expect(page.rooms.count == 1)
    }

    @Test("Fresh rooms with a new token continue pagination")
    func freshPageContinues() {
        var page = self.page()
        BrowseRoomsViewModel.applyPage(
            rooms: [entry("!b:example.com")], nextBatch: "t1",
            sentBatch: "t0", to: &page)
        #expect(!page.isAtEnd)
        #expect(page.rooms.count == 2)
        #expect(page.nextBatch == "t1")
    }
}
