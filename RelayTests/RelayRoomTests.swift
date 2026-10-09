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
import MatrixKitSwiftData
import SwiftData
import Testing

@testable import Relay

// MARK: - RelayRoomTests

/// Store-backed room snapshots and their row mapping: DM heuristics,
/// avatar fallback, invite attribution, and the reaction lookup behind
/// toggle-off.
struct RelayRoomTests {
    private func room() -> RelayRoom {
        RelayRoom(
            roomId: RoomId(unchecked: "!test:example.com"),
            displayName: "Test",
            membership: .join,
            localUserId: UserId(unchecked: "@me:example.com"))
    }

    private func textEvent(
        id: String, sender: String, body: String, ts: Int = 1_000
    ) -> MessageEvent {
        MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: id),
            sender: UserId(unchecked: sender),
            roomId: RoomId(unchecked: "!test:example.com"),
            originServerTs: ts,
            content: [
                "msgtype": .string("m.text"),
                "body": .string(body),
            ])
    }

    private func reactionEvent(
        id: String, target: String, key: String, sender: String
    ) -> MessageEvent {
        MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: id),
            sender: UserId(unchecked: sender),
            roomId: RoomId(unchecked: "!test:example.com"),
            originServerTs: 2_000,
            content: [
                "m.relates_to": .object([
                    "rel_type": .string("m.annotation"),
                    "event_id": .string(target),
                    "key": .string(key),
                ])
            ])
    }

    @Test func emptyRoomPresentsAsDirect() {
        // No members yet (lazy loading): the heuristic treats an
        // unaliased room as DM-like, matching previous behavior.
        #expect(room().presentsAsDirect)
    }

    @Test func threeJoinedMembersIsNotDirect() {
        var room = self.room()
        let me = UserId(unchecked: "@me:example.com")
        room.memberDetails = [
            me: MemberContent(membership: .join),
            UserId(unchecked: "@a:example.com"): MemberContent(membership: .join),
            UserId(unchecked: "@b:example.com"): MemberContent(membership: .join),
        ]
        #expect(!room.presentsAsDirect)
    }

    @Test func presentingAvatarFallsBackToPeerInDM() {
        var room = self.room()
        room.memberDetails = [
            UserId(unchecked: "@me:example.com"): MemberContent(membership: .join),
            UserId(unchecked: "@peer:example.com"): MemberContent(
                membership: .join, displayname: "Peer",
                avatarUrl: "mxc://example.com/avatar"),
        ]
        #expect(room.presentingAvatarURL?.value == "mxc://example.com/avatar")
    }

    @Test func roomAvatarWinsOverPeerAvatar() {
        var room = self.room()
        room.avatarURL = try? MXCURI("mxc://example.com/room")
        room.memberDetails = [
            UserId(unchecked: "@peer:example.com"): MemberContent(
                membership: .join, avatarUrl: "mxc://example.com/peer"),
        ]
        #expect(room.presentingAvatarURL?.value == "mxc://example.com/room")
    }

    @Test func inviteAttributionFallsBackToMXID() {
        var room = self.room()
        room.membership = .invite
        room.inviterId = UserId(unchecked: "@inviter:example.com")
        #expect(room.inviterName == "@inviter:example.com")
        #expect(room.inviterAvatarURL == nil)
    }

    @Test func rowMappingCarriesPreviewAndCounts() {
        var room = self.room()
        room.unreadCount = 3
        room.highlightCount = 1
        room.memberDetails = [
            UserId(unchecked: "@alice:example.com"): MemberContent(
                membership: .join, displayname: "Alice"),
        ]
        room.latestMessage = textEvent(
            id: "$m1", sender: "@alice:example.com", body: "Hello")
        room.parentSpaceIds = [RoomId(unchecked: "!space:example.com")]
        let row = RoomRowData.from(room: room, isMuted: false)
        #expect(row.roomId == "!test:example.com")
        #expect(row.name == "Test")
        #expect(row.lastMessage == "Hello")
        #expect(row.lastMessageAuthor == "Alice")
        #expect(row.lastMessageTimestamp != nil)
        #expect(row.notificationCount == 3)
        #expect(row.highlightCount == 1)
        #expect(row.parentSpaceIds == ["!space:example.com"])
        #expect(!row.isArchived)
    }

    @Test func rowMappingMarksSuccessorAsArchived() {
        var room = self.room()
        room.successorRoomId = "!new:example.com"
        #expect(RoomRowData.from(room: room, isMuted: false).isArchived)
    }

    @Test func displayUnreadPrefersEffectiveOverServerCount() {
        // Regression: the sidebar badge must follow the writer's
        // client-estimated unread, not the raw server count (which
        // undercounts, e.g. zeroed by a stale receipt).
        let row = SDRoom(
            roomId: "!test:example.com",
            membership: Membership.join.rawValue,
            unread: 0,
            highlight: 0,
            effectiveUnread: 4)
        let room = RelayClient.relayRoom(row: row, members: [])
        #expect(room.unreadCount == 4)
        #expect(RoomRowData.from(room: room, isMuted: false).notificationCount == 4)
    }

    @Test func reactionLookupFindsOwnReaction() {
        let target = EventId(unchecked: "$target")
        let me = UserId(unchecked: "@me:example.com")
        let events = [
            textEvent(id: "$target", sender: "@a:example.com", body: "Hi"),
            reactionEvent(id: "$r1", target: "$target", key: "👍", sender: "@me:example.com"),
        ]
        #expect(events.reactionEvent(target: target, key: "👍", sender: me)?.value == "$r1")
    }

    @Test func reactionLookupIgnoresOtherKeysAndSenders() {
        let target = EventId(unchecked: "$target")
        let me = UserId(unchecked: "@me:example.com")
        let events = [
            reactionEvent(id: "$r1", target: "$target", key: "👍", sender: "@other:example.com"),
        ]
        #expect(events.reactionEvent(target: target, key: "👍", sender: me) == nil)
        #expect(events.reactionEvent(
            target: target, key: "❤️",
            sender: UserId(unchecked: "@other:example.com")) == nil)
    }

    @Test func spaceChildEdgeMakesChildKnowItsParent() {
        // Regression: `m.space.child` lives in the parent's state
        // (owner = parent, peer = child). Subspaces with empty parents
        // render as top-level rail entries instead of nesting.
        let edges = [
            SDRoomEdge(
                ownerRoomId: "!parent:example.com",
                peerRoomId: "!sub:example.com",
                kind: .child),
        ]
        #expect(SDRoomEdge.parents(of: "!sub:example.com", in: edges) == ["!parent:example.com"])
        #expect(SDRoomEdge.parents(of: "!parent:example.com", in: edges) == [])
    }

    @Test func spaceParentEdgeMakesOwnerKnowItsParent() {
        // `m.space.parent` lives in the child's state (owner = child,
        // peer = parent).
        let edges = [
            SDRoomEdge(
                ownerRoomId: "!sub:example.com",
                peerRoomId: "!parent:example.com",
                kind: .parent),
        ]
        #expect(SDRoomEdge.parents(of: "!sub:example.com", in: edges) == ["!parent:example.com"])
        #expect(SDRoomEdge.parents(of: "!parent:example.com", in: edges) == [])
    }

    @Test func windowAnchorKeepsStoredAnchorInWindow() {
        let snapshot = [
            textEvent(id: "$a", sender: "@a:example.com", body: "A", ts: 1_000),
            textEvent(id: "$b", sender: "@a:example.com", body: "B", ts: 2_000),
        ]
        #expect(TimelineViewModel.windowAnchor(snapshot: snapshot, storedAnchor: "$b") == "$b")
    }

    @Test func windowAnchorFallsBackToWindowFirstWhenStoredPredatesWindow() {
        // Regression: the store anchors to the oldest unread in full
        // history, which can predate the loaded window and match no
        // rendered row (no divider). The retired live timeline anchored
        // window-first in that case.
        let snapshot = [
            textEvent(id: "$c", sender: "@a:example.com", body: "C", ts: 3_000),
            textEvent(id: "$d", sender: "@a:example.com", body: "D", ts: 4_000),
        ]
        #expect(TimelineViewModel.windowAnchor(snapshot: snapshot, storedAnchor: "$a") == "$c")
    }

    @Test func windowAnchorIsNilWhenFullyRead() {
        let snapshot = [
            textEvent(id: "$a", sender: "@a:example.com", body: "A", ts: 1_000),
        ]
        #expect(TimelineViewModel.windowAnchor(snapshot: snapshot, storedAnchor: nil) == nil)
        #expect(TimelineViewModel.windowAnchor(snapshot: [], storedAnchor: "$a") == nil)
    }

    @Test func windowSizeGrowsByFetchedPages() {
        #expect(TimelineViewModel.grownWindowSize(current: 500, fetched: 50) == 550)
        #expect(TimelineViewModel.grownWindowSize(current: 500, fetched: 0) == 500)
    }

    @Test func windowSizeClampsAtMaximum() {
        #expect(TimelineViewModel.grownWindowSize(current: 1990, fetched: 50) == 2000)
        #expect(TimelineViewModel.grownWindowSize(current: 2000, fetched: 50) == 2000)
    }

    @Test func descendantsSpanMultipleHops() {
        // Fedora → Project Teams → #room: the room matches the Fedora
        // filter despite no direct edge.
        let fedora = RoomId(unchecked: "!fedora:example.com")
        let teams = RoomId(unchecked: "!teams:example.com")
        let room = RoomId(unchecked: "!room:example.com")
        let children: [RoomId: Set<RoomId>] = [
            fedora: [teams],
            teams: [room],
        ]
        let found = RelayClient.descendants(of: fedora, children: children)
        // Intermediate subspaces included; the room list drops them via
        // its own isSpace filter.
        #expect(found == [teams.value, room.value])
    }

    @Test func descendantsAreCycleSafeAndExcludeSelf() {
        let a = RoomId(unchecked: "!a:example.com")
        let b = RoomId(unchecked: "!b:example.com")
        let children: [RoomId: Set<RoomId>] = [a: [b], b: [a]]
        #expect(RelayClient.descendants(of: a, children: children) == [b.value])
        #expect(RelayClient.descendants(
            of: RoomId(unchecked: "!empty:example.com"), children: children) == [])
    }

    @Test func spaceChildrenUnionEdgesAndHierarchyBlobs() async throws {
        let fedora = SDRoom(roomId: "!fedora:example.com", membership: "join")
        let teams = RoomId(unchecked: "!teams:example.com")
        let room = RoomId(unchecked: "!room:example.com")
        // Synced state edge: Fedora lists Teams.
        let edge = SDRoomEdge(
            ownerRoomId: fedora.roomId, peerRoomId: teams.value, kind: .child)
        // Fetched hierarchy blob: Teams lists the room (unjoined branch
        // whose own state never syncs), with grandchild edges inline.
        let listed = SpaceChild(roomId: teams, childIds: [room])
        fedora.hierarchyChildren = try JSONEncoder().encode([listed])
        let children = RoomIndexBuilder.spaceChildrenByParent(
            rows: [fedora], edges: [edge])
        #expect(children[RoomId(unchecked: fedora.roomId)] == [teams])
        #expect(children[teams] == [room])
    }

    @Test func builderRebuildMapsEffectiveUnreadAndPreview() async throws {
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let room = SDRoom(
            roomId: "!test:example.com", membership: Membership.join.rawValue,
            name: "Test", unread: 0, effectiveUnread: 2)
        context.insert(room)
        let member = SDRoomMember(
            roomId: "!test:example.com", userId: "@alice:example.com",
            membership: Membership.join.rawValue, displayname: "Alice")
        member.room = room
        context.insert(member)
        let encoder = JSONEncoder()
        for (id, ts, body) in [("$m1", 1_000, "First"), ("$m2", 2_000, "Second")] {
            let content = try encoder.encode([
                "msgtype": AnyCodable.string("m.text"),
                "body": AnyCodable.string(body),
            ])
            let row = SDRoomEvent(
                roomId: "!test:example.com", eventId: id, ts: ts,
                type: "m.room.message", sender: "@alice:example.com",
                content: content, isMessageLike: true)
            row.room = room
            context.insert(row)
        }
        try context.save()

        let builder = RoomIndexBuilder(
            container: container, localUser: UserId(unchecked: "@me:example.com"))
        let result = await builder.rebuild()
        #expect(result.joined.count == 1)
        let built = try #require(result.joined.first)
        // Effective (not server) unread, newest message preview.
        #expect(built.unreadCount == 2)
        #expect(built.latestMessage?.eventId.value == "$m2")
        #expect(built.newestEventId == "$m2")
        #expect(built.memberDetails[UserId(unchecked: "@alice:example.com")]?.displayname == "Alice")
    }

    @Test func builderPayloadCarriesWindowSendStatesAndMarkers() async throws {
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let room = SDRoom(
            roomId: "!test:example.com", membership: Membership.join.rawValue,
            firstUnreadEventId: "$m2", prevBatch: "s1")
        context.insert(room)
        let encoder = JSONEncoder()
        let content = try encoder.encode([
            "msgtype": AnyCodable.string("m.text"),
            "body": AnyCodable.string("Hi"),
        ])
        let echo = SDRoomEvent(
            roomId: "!test:example.com", eventId: "local:txn1", ts: 3_000,
            type: "m.room.message", sender: "@me:example.com",
            content: content, isMessageLike: true, sendState: "pending")
        echo.room = room
        context.insert(echo)
        try context.save()

        let builder = RoomIndexBuilder(container: container, localUser: nil)
        let payload = await builder.timelinePayload(roomId: "!test:example.com", limit: 50)
        #expect(payload.snapshot.map(\.eventId.value) == ["local:txn1"])
        #expect(payload.sendStates[EventId(unchecked: "local:txn1")] == .pending)
        #expect(payload.firstUnreadEventId == "$m2")
        #expect(payload.prevBatch == "s1")
        let marker = await builder.markerSummary(roomId: "!test:example.com")
        #expect(marker.firstUnreadEventId == "$m2")
        #expect(marker.prevBatch == "s1")
    }
}
