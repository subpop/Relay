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

// MARK: - DockBadgeControllerTests

struct DockBadgeControllerTests {
    private typealias State = DockBadgeController.RoomBadgeState

    private func state(
        mode: RoomNotificationMode? = nil,
        unread: Int = 0,
        highlight: Int = 0,
        isDirect: Bool = false
    ) -> State {
        State(mode: mode, unread: unread, highlight: highlight, isDirect: isDirect)
    }

    @Test func emptyRoomsCountZero() {
        #expect(DockBadgeController.badgeCount(for: []) == 0)
    }

    @Test func mutedRoomsCountNothing() {
        let rooms = [state(mode: .mute, unread: 5, highlight: 3)]
        #expect(DockBadgeController.badgeCount(for: rooms) == 0)
    }

    @Test func allMessagesCountsUnread() {
        let rooms = [state(mode: .allMessages, unread: 4, highlight: 1)]
        #expect(DockBadgeController.badgeCount(for: rooms) == 4)
    }

    @Test func mentionsOnlyCountsHighlights() {
        let rooms = [state(mode: .mentionsAndKeywordsOnly, unread: 4, highlight: 2)]
        #expect(DockBadgeController.badgeCount(for: rooms) == 2)
    }

    @Test func defaultDirectRoomCountsUnread() {
        let rooms = [state(unread: 3, highlight: 1, isDirect: true)]
        #expect(DockBadgeController.badgeCount(for: rooms) == 3)
    }

    @Test func defaultGroupRoomCountsHighlights() {
        let rooms = [state(unread: 3, highlight: 1, isDirect: false)]
        #expect(DockBadgeController.badgeCount(for: rooms) == 1)
    }

    @Test func mixedRoomsSum() {
        let rooms = [
            state(mode: .mute, unread: 9, highlight: 9),
            state(mode: .allMessages, unread: 4, highlight: 1),
            state(mode: .mentionsAndKeywordsOnly, unread: 4, highlight: 2),
            state(unread: 3, highlight: 0, isDirect: true),
            state(unread: 7, highlight: 1, isDirect: false),
        ]
        #expect(DockBadgeController.badgeCount(for: rooms) == 4 + 2 + 3 + 1)
    }
}
