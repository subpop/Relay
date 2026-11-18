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

@Suite @MainActor
struct ComposeMentionTests {

    @Test func matchesEmojiDecoratedNameAndPreservesMemberOrder() {
        let compose = ComposeViewModel()
        let substringMatch = RoomMemberDetails(
            userId: UserId(unchecked: "@stomper:example.org"), displayName: "Stomper"
        )
        let decoratedName = RoomMemberDetails(
            userId: UserId(unchecked: "@tom:example.org"),
            displayName: "🏴‍☠️🐰Ťom 🐰🏴‍☠️"
        )
        compose.members = [substringMatch, decoratedName]
        compose.mentionQuery = "tom"

        #expect(compose.filteredMentionMembers.map(\.id) == [substringMatch.id, decoratedName.id])

        compose.mentionQuery = "🐰"
        #expect(compose.filteredMentionMembers.map(\.id) == [decoratedName.id])
    }

    @Test func matchesCanonicallyEquivalentAccentedQuery() {
        let compose = ComposeViewModel()
        let member = RoomMemberDetails(
            userId: UserId(unchecked: "@tom:example.org"), displayName: "Ťom"
        )
        compose.members = [member]
        compose.mentionQuery = "T\u{030C}om"

        #expect(compose.filteredMentionMembers.map(\.id) == [member.id])
    }

    @Test func matchesLatinAsciiTransliterationsInBothDirections() {
        let compose = ComposeViewModel()
        let ethName = RoomMemberDetails(
            userId: UserId(unchecked: "@eth:example.org"), displayName: "Ðave"
        )
        let plainName = RoomMemberDetails(
            userId: UserId(unchecked: "@dave:example.org"), displayName: "Dave"
        )
        compose.members = [ethName, plainName]

        compose.mentionQuery = "dave"
        #expect(compose.filteredMentionMembers.map(\.id).contains(ethName.id))

        compose.mentionQuery = "Ðave"
        #expect(compose.filteredMentionMembers.map(\.id).contains(plainName.id))
    }

    @Test func matchesMatrixIdAlongsideDisplayName() {
        let compose = ComposeViewModel()
        let member = RoomMemberDetails(
            userId: UserId(unchecked: "@bob:example.org"), displayName: "Robert"
        )
        compose.members = [member]
        compose.mentionQuery = "bob:example"

        #expect(compose.filteredMentionMembers.map(\.id) == [member.id])
    }
}
