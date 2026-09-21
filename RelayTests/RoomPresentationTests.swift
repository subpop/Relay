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

// MARK: - RoomPresentationTests

struct RoomPresentationTests {

    @Test func specDirectStaysDirect() {
        #expect(RoomPresentation.presentsAsDirect(
            isDirect: true, isSpace: false,
            canonicalAlias: "#group:x", joinedMemberCount: 50))
    }

    @Test func twoMembersWithoutAliasPresentsAsDirect() {
        #expect(RoomPresentation.presentsAsDirect(
            isDirect: false, isSpace: false,
            canonicalAlias: nil, joinedMemberCount: 2))
    }

    @Test func aliasedRoomNeverHeuristicDirect() {
        // Regression: a public, aliased room with a partially synced
        // member list must not present as a DM.
        #expect(!RoomPresentation.presentsAsDirect(
            isDirect: false, isSpace: false,
            canonicalAlias: "#relay-echo:matrix.org", joinedMemberCount: 2))
    }

    @Test func largerRoomWithoutAliasIsNotDirect() {
        #expect(!RoomPresentation.presentsAsDirect(
            isDirect: false, isSpace: false,
            canonicalAlias: nil, joinedMemberCount: 3))
    }

    @Test func spaceNeverHeuristicDirect() {
        #expect(!RoomPresentation.presentsAsDirect(
            isDirect: false, isSpace: true,
            canonicalAlias: nil, joinedMemberCount: 1))
    }
}
