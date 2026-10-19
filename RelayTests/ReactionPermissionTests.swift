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

@Suite("Reaction permission controls")
struct ReactionPermissionTests {
    @MainActor
    @Test func reactionsRemainAvailableWithoutMessagePermission() {
        let message = PreviewFixtures.event(
            "reaction-permission", sender: "@alice:example.com", body: "Hello")
        let permissions = RoomPermissions(
            canSendMessages: false, canSendReactions: true, canSendRedactions: false)

        let entries = TimelineMessageContextMenu.entries(
            for: message, isOutgoing: false, permissions: permissions)

        #expect(entries.contains(.quickReactions))
        #expect(entries.contains(.addReaction))
        #expect(!entries.contains(.reply))
    }

    @MainActor
    @Test func messagePermissionDoesNotImplyReactionPermission() {
        let message = PreviewFixtures.event(
            "message-only-permission", sender: "@alice:example.com", body: "Hello")
        let permissions = RoomPermissions(
            canSendMessages: true, canSendReactions: false)

        let entries = TimelineMessageContextMenu.entries(
            for: message, isOutgoing: false, permissions: permissions)

        #expect(entries.contains(.reply))
        #expect(!entries.contains(.quickReactions))
        #expect(!entries.contains(.addReaction))
    }

    @Test func addingAndWithdrawingReactionsUseSeparatePermissions() {
        let addOnly = RoomPermissions(
            canSendReactions: true, canSendRedactions: false)
        let withdrawOnly = RoomPermissions(
            canSendReactions: false, canSendRedactions: true)

        #expect(TimelineMessageContextMenu.canToggleReaction(
            key: "👍", ownReactions: [], permissions: addOnly))
        #expect(!TimelineMessageContextMenu.canToggleReaction(
            key: "👍", ownReactions: ["👍"], permissions: addOnly))
        #expect(TimelineMessageContextMenu.canToggleReaction(
            key: "👍", ownReactions: ["👍"], permissions: withdrawOnly))
        #expect(!TimelineMessageContextMenu.canToggleReaction(
            key: "👍", ownReactions: [], permissions: withdrawOnly))
    }

    @Test func reactionControlsDefaultToStandardPreviewPermissions() {
        #expect(TimelineMessageContextMenu.canToggleReaction(
            key: "🎉", ownReactions: [], permissions: nil))
        #expect(TimelineMessageContextMenu.canToggleReaction(
            key: "🎉", ownReactions: ["🎉"], permissions: nil))
    }
}
