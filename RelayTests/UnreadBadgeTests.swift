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

import Testing

@testable import Relay

// MARK: - UnreadBadgeTests

/// Unread tier math behind the room list's indicator: plain unreads read
/// quietly, while mentions and DM activity need attention and turn the
/// indicator red.
struct UnreadBadgeTests {
    private func room(
        notificationCount: Int = 0,
        highlightCount: Int = 0,
        isDirect: Bool = false
    ) -> RoomRowData {
        RoomRowData(
            roomId: "!test:example.com",
            name: "Test",
            notificationCount: notificationCount,
            highlightCount: highlightCount,
            isDirect: isDirect)
    }

    @Test func plainUnreadNeedsNoAttention() {
        #expect(!room(notificationCount: 5).needsAttention)
    }

    @Test func highlightNeedsAttention() {
        #expect(room(notificationCount: 5, highlightCount: 2).needsAttention)
    }

    @Test func directMessageUnreadNeedsAttention() {
        #expect(room(notificationCount: 4, isDirect: true).needsAttention)
    }

    @Test func noUnreadNeedsNoAttention() {
        #expect(!room().needsAttention)
    }

    @Test func noUnreadDirectNeedsNoAttention() {
        #expect(!room(isDirect: true).needsAttention)
    }
}
