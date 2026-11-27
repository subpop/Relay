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

struct JoinedRoomHistoryBackfillTests {
    @Test func backfillsShortTimelineWhenCursorExists() {
        #expect(RelayClient.shouldBackfillJoinedRoomHistory(
            eventCount: 0, hasPreviousBatch: true))
        #expect(RelayClient.shouldBackfillJoinedRoomHistory(
            eventCount: 10, hasPreviousBatch: true))
    }

    @Test func skipsLongTimelineOrMissingCursor() {
        #expect(!RelayClient.shouldBackfillJoinedRoomHistory(
            eventCount: 11, hasPreviousBatch: true))
        #expect(!RelayClient.shouldBackfillJoinedRoomHistory(
            eventCount: 10, hasPreviousBatch: false))
    }
}
