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

    private func pollEvent(id: String, sender: String, question: String) -> MessageEvent {
        MessageEvent(
            type: "m.poll.start",
            eventId: EventId(unchecked: id),
            sender: UserId(unchecked: sender),
            roomId: RoomId(unchecked: "!test:example.com"),
            originServerTs: 3_000,
            content: [
                "m.text": .array([
                    .object(["body": .string("\(question)\n1. Pizza")]),
                ]),
                "m.poll": .object([
                    "kind": .string("m.disclosed"),
                    "max_selections": .int(1),
                    "answers": .array([
                        .object([
                            "m.id": .string("a1"),
                            "m.text": .array([
                                .object(["body": .string("Pizza")]),
                            ]),
                        ]),
                    ]),
                    "question": .object([
                        "m.text": .array([
                            .object(["body": .string(question)]),
                        ]),
                    ]),
                ]),
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

    @Test func rowMappingPreviewsPollQuestion() {
        var room = self.room()
        room.memberDetails = [
            UserId(unchecked: "@alice:example.com"): MemberContent(
                membership: .join, displayname: "Alice"),
        ]
        room.latestMessage = pollEvent(
            id: "$p1", sender: "@alice:example.com", question: "Lunch?")
        let row = RoomRowData.from(room: room, isMuted: false)
        #expect(row.lastMessage == "Lunch?")
        #expect(row.lastMessageAuthor == "Alice")
        #expect(row.lastMessageTimestamp != nil)
    }

    @Test func legacyPollContentDoesNotDecodeAsPoll() {
        // The pre-tightening wire shape Draupnir's InvalidEventProtection
        // redacted: a bare-string `m.text` fallback under `m.poll.start`.
        let data = """
            {"m.poll.start":{"answers":[{"id":"0","org.matrix.msc1767.text":"Yes"},\
            {"id":"1","org.matrix.msc1767.text":"No"}],"kind":"m.poll.disclosed",\
            "max_selections":1,\
            "question":{"org.matrix.msc1767.text":"This is a test poll"}},\
            "m.text":"This is a test poll"}
            """.data(using: .utf8)!
        #expect((try? JSONDecoder().decode(PollStartContent.self, from: data)) == nil)
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

    @Test func dmDisplayNamePrefersMemberDisplayname() {
        // Regression (0.6.5): DM rooms rendered the peer's user ID
        // instead of their display name.
        let row = SDRoom(
            roomId: "!test:example.com",
            membership: Membership.join.rawValue)
        let members = [
            SDRoomMember(
                roomId: "!test:example.com", userId: "@alice:example.com",
                membership: Membership.join.rawValue, displayname: "Alice"),
            SDRoomMember(
                roomId: "!test:example.com", userId: "@me:example.com",
                membership: Membership.join.rawValue, displayname: "Me"),
        ]
        let room = RelayClient.relayRoom(
            row: row, members: members,
            localUser: UserId(unchecked: "@me:example.com"))
        #expect(room.displayName == "Alice")
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

    @Test func liveAnchorCandidatesPreferUnreadThenFullyRead() {
        #expect(TimelineViewModel.liveAnchorCandidates(
            fullyReadEventId: "$fr", firstUnreadEventId: "$u",
            hasUnread: true) == ["$u", "$fr"])
    }

    @Test func liveAnchorCandidatesDeduplicateAndDropNils() {
        #expect(TimelineViewModel.liveAnchorCandidates(
            fullyReadEventId: "$same", firstUnreadEventId: "$same",
            hasUnread: true) == ["$same"])
        #expect(TimelineViewModel.liveAnchorCandidates(
            fullyReadEventId: nil, firstUnreadEventId: "$u",
            hasUnread: true) == ["$u"])
        #expect(TimelineViewModel.liveAnchorCandidates(
            fullyReadEventId: nil, firstUnreadEventId: nil,
            hasUnread: true).isEmpty)
    }

    @Test func liveAnchorCandidatesStayLiveWhenRoomHasNoUnreadMessages() {
        #expect(TimelineViewModel.liveAnchorCandidates(
            fullyReadEventId: "$fully-read",
            firstUnreadEventId: nil,
            hasUnread: false).isEmpty)
    }

    @Test func liveWindowKeepsOlderEdgeWhenPagingBack() {
        #expect(TimelineViewModel.liveSlice(Array(0..<150), keeping: .older) == Array(0..<100))
        #expect(TimelineViewModel.liveSlice(Array(0..<50), keeping: .older).count == 50)
    }

    @Test func liveWindowKeepsNewerEdgeWhenPagingForward() {
        #expect(TimelineViewModel.liveSlice(Array(0..<150), keeping: .newer) == Array(50..<150))
        #expect(TimelineViewModel.liveSlice(Array(0..<50), keeping: .newer).count == 50)
    }

    @Test func focusedWindowSlidesOverBufferedEvents() {
        let events = Array(0..<150)
        #expect(TimelineViewModel.focusedSlice(events, start: 0) == Array(0..<100))
        #expect(TimelineViewModel.focusedSlice(events, start: 50) == Array(50..<150))
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

    @Test func builderPreviewFallsBackPastRedactedNewestMessage() async throws {
        // Regression: redacting the newest message blanked the room-list
        // preview (pruned content decodes as no message). The index must
        // walk back to the last non-redacted message instead.
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let room = SDRoom(
            roomId: "!test:example.com", membership: Membership.join.rawValue,
            name: "Test")
        context.insert(room)
        let encoder = JSONEncoder()
        let first = SDRoomEvent(
            roomId: "!test:example.com", eventId: "$m1", ts: 1_000,
            type: "m.room.message", sender: "@alice:example.com",
            content: try encoder.encode([
                "msgtype": AnyCodable.string("m.text"),
                "body": AnyCodable.string("First"),
            ]),
            isMessageLike: true)
        first.room = room
        context.insert(first)
        // Redacted target as the store persists it: content pruned to the
        // keep-list (empty for messages) plus the `redacted_because` stamp.
        let redacted = SDRoomEvent(
            roomId: "!test:example.com", eventId: "$m2", ts: 2_000,
            type: "m.room.message", sender: "@alice:example.com",
            content: try encoder.encode([String: AnyCodable]()),
            unsigned: try encoder.encode([
                "redacted_because": AnyCodable.object([
                    "type": .string("m.room.redaction"),
                    "event_id": .string("$r1"),
                    "sender": .string("@alice:example.com"),
                    "redacts": .string("$m2"),
                ]),
            ]),
            isMessageLike: true)
        redacted.room = room
        context.insert(redacted)
        try context.save()

        let builder = RoomIndexBuilder(
            container: container, localUser: UserId(unchecked: "@me:example.com"))
        let result = await builder.rebuild()
        let built = try #require(result.joined.first)
        // Preview, author, and timestamp revert to the older message;
        // the newest stored event of any type is unchanged.
        #expect(built.latestMessage?.eventId.value == "$m1")
        #expect(built.newestEventId == "$m2")
        let row = RoomRowData.from(room: built, isMuted: false)
        #expect(row.lastMessage == "First")
        #expect(row.lastMessageTimestamp == Date(timeIntervalSince1970: 1))
    }

    @Test func builderPreviewNilWhenEveryMessageRedacted() async throws {
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let room = SDRoom(
            roomId: "!test:example.com", membership: Membership.join.rawValue,
            name: "Test")
        context.insert(room)
        let encoder = JSONEncoder()
        let redacted = SDRoomEvent(
            roomId: "!test:example.com", eventId: "$m1", ts: 1_000,
            type: "m.room.message", sender: "@alice:example.com",
            content: try encoder.encode([String: AnyCodable]()),
            unsigned: try encoder.encode([
                "redacted_because": AnyCodable.object([
                    "type": .string("m.room.redaction"),
                    "event_id": .string("$r1"),
                    "sender": .string("@alice:example.com"),
                    "redacts": .string("$m1"),
                ]),
            ]),
            isMessageLike: true)
        redacted.room = room
        context.insert(redacted)
        try context.save()

        let builder = RoomIndexBuilder(
            container: container, localUser: UserId(unchecked: "@me:example.com"))
        let result = await builder.rebuild()
        let built = try #require(result.joined.first)
        #expect(built.latestMessage == nil)
        #expect(RoomRowData.from(room: built, isMuted: false).lastMessage == nil)
    }

    @Test func memberDetailsBuildsFromStoredRows() async throws {
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let room = SDRoom(roomId: "!test:example.com", membership: "join")
        let encoder = JSONEncoder()
        room.powerLevelsContent = try encoder.encode([
            "users_default": AnyCodable.int(0),
            "users": AnyCodable.object(["@alice:example.com": .int(50)]),
        ])
        room.createEventSender = "@creator:example.com"
        room.createEventContent = try encoder.encode([
            "room_version": AnyCodable.string("12"),
        ])
        context.insert(room)
        for (userId, membership, displayName) in [
            ("@creator:example.com", "join", "Creator"),
            ("@alice:example.com", "join", "Alice"),
            ("@invite:example.com", "invite", "Invite"),
            ("@left:example.com", "leave", "Left"),
        ] {
            let member = SDRoomMember(
                roomId: room.roomId,
                userId: userId,
                membership: membership,
                displayname: displayName)
            member.room = room
            context.insert(member)
        }
        try context.save()

        let builder = RoomIndexBuilder(container: container, localUser: nil)
        let members = await builder.memberDetails(roomId: room.roomId)
        #expect(members.map(\.displayName) == ["Alice", "Creator", "Invite"])
        #expect(members.first { $0.userId.value == "@creator:example.com" }?.isCreator == true)
        #expect(members.first { $0.userId.value == "@creator:example.com" }?.powerLevel == .max)
        #expect(members.first { $0.userId.value == "@alice:example.com" }?.powerLevel == 50)
    }

    @Test func timelinePayloadReadsIndependentlyOfRoomIndexRebuild() async throws {
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

        let reader = TimelinePayloadReader(
            reader: MatrixStoreReader(modelContainer: container))
        let builder = RoomIndexBuilder(container: container, localUser: nil)
        async let rebuild = builder.rebuild()
        async let timeline = reader.timelinePayload(
            roomId: RoomId(unchecked: "!test:example.com"), limit: 50)
        let (rooms, payload) = await (rebuild, timeline)
        #expect(rooms.joined.count == 1)
        #expect(payload.snapshot.map(\.eventId.value) == ["local:txn1"])
        #expect(payload.sendStates[EventId(unchecked: "local:txn1")] == .pending)
        #expect(payload.firstUnreadEventId == "$m2")
        #expect(payload.prevBatch == "s1")
        let marker = await reader.markerSummary(
            roomId: RoomId(unchecked: "!test:example.com"))
        #expect(marker.firstUnreadEventId == "$m2")
        #expect(marker.prevBatch == "s1")
    }

    @Test func anchoredTimelineSliceIncludesTimestampTiesInStableOrder() async throws {
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let room = SDRoom(
            roomId: "!test:example.com", membership: Membership.join.rawValue,
            firstUnreadEventId: "$b", prevBatch: "older")
        context.insert(room)
        for (id, body) in [("$a", "A"), ("$b", "B"), ("$c", "C")] {
            let event = textEvent(
                id: id, sender: "@alice:example.com", body: body, ts: 1_000)
            let row = SDRoomEvent(
                roomId: "!test:example.com",
                eventId: event.eventId.value,
                ts: event.originServerTs,
                type: event.type,
                sender: event.sender.value,
                content: try JSONEncoder().encode(event.content),
                searchableText: body,
                isMessageLike: true)
            row.room = room
            context.insert(row)
        }
        try context.save()

        let reader = TimelinePayloadReader(
            reader: MatrixStoreReader(modelContainer: container))
        let payload = try #require(await reader.timelinePayloadAround(
            roomId: RoomId(unchecked: "!test:example.com"),
            anchorEventId: "$b",
            olderLimit: 1,
            newerLimit: 1))

        #expect(payload.snapshot.map(\.eventId.value) == ["$a", "$b", "$c"])
        #expect(!payload.hasOlderStoredEvents)
        #expect(!payload.hasNewerStoredEvents)
        #expect(payload.firstUnreadEventId == "$b")
        #expect(payload.prevBatch == "older")
    }

    @Test func anchoredTimelineSliceReportsMoreStoredEvents() async throws {
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let room = SDRoom(roomId: "!test:example.com", membership: Membership.join.rawValue)
        context.insert(room)
        for (id, ts) in [("$a", 1_000), ("$b", 2_000), ("$c", 3_000)] {
            let event = textEvent(
                id: id, sender: "@alice:example.com", body: id, ts: ts)
            let row = SDRoomEvent(
                roomId: "!test:example.com",
                eventId: event.eventId.value,
                ts: event.originServerTs,
                type: event.type,
                sender: event.sender.value,
                content: try JSONEncoder().encode(event.content),
                isMessageLike: true)
            row.room = room
            context.insert(row)
        }
        try context.save()

        let reader = TimelinePayloadReader(
            reader: MatrixStoreReader(modelContainer: container))
        let payload = try #require(await reader.timelinePayloadAround(
            roomId: RoomId(unchecked: "!test:example.com"),
            anchorEventId: "$b",
            olderLimit: 0,
            newerLimit: 0))

        #expect(payload.snapshot.map(\.eventId.value) == ["$b"])
        #expect(payload.hasOlderStoredEvents)
        #expect(payload.hasNewerStoredEvents)
    }

    @Test func liveWindowSlidesThroughStoredHistoryInBothDirections() async throws {
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let roomId = RoomId(unchecked: "!test:example.com")
        let room = SDRoom(roomId: roomId.value, membership: Membership.join.rawValue)
        context.insert(room)
        for index in 0..<6 {
            let event = textEvent(
                id: "$\(index)", sender: "@alice:example.com",
                body: "\(index)", ts: index * 1_000)
            let row = SDRoomEvent(
                roomId: roomId.value, eventId: event.eventId.value,
                ts: event.originServerTs, type: event.type,
                sender: event.sender.value,
                content: try JSONEncoder().encode(event.content), isMessageLike: true)
            row.room = room
            context.insert(row)
        }
        try context.save()

        let reader = TimelinePayloadReader(reader: MatrixStoreReader(modelContainer: container))
        let latest = await reader.timelinePayload(roomId: roomId, limit: 3)
        #expect(latest.snapshot.map(\.eventId.value) == ["$3", "$4", "$5"])

        let older = try #require(await reader.timelinePayloadAround(
            roomId: roomId, anchorEventId: "$3", olderLimit: 1, newerLimit: 2))
        let back = TimelineViewModel.liveSlice(older.snapshot, keeping: .older, limit: 3)
        #expect(back.map(\.eventId.value) == ["$2", "$3", "$4"])
        #expect(older.hasOlderStoredEvents)
        #expect(older.snapshot.count > back.count)

        let newer = try #require(await reader.timelinePayloadAround(
            roomId: roomId, anchorEventId: "$4", olderLimit: 2, newerLimit: 1))
        let forward = TimelineViewModel.liveSlice(newer.snapshot, keeping: .newer, limit: 3)
        #expect(forward.map(\.eventId.value) == ["$3", "$4", "$5"])
        #expect(newer.hasOlderStoredEvents)
        #expect(!newer.hasNewerStoredEvents)
    }

    @Test func unreadWindowSlidesAroundStoredAnchor() async throws {
        let container = try MatrixStore.makeInMemory()
        let context = ModelContext(container)
        let roomId = RoomId(unchecked: "!test:example.com")
        let room = SDRoom(roomId: roomId.value, membership: Membership.join.rawValue)
        context.insert(room)
        for index in 0..<150 {
            let event = textEvent(
                id: "$\(index)", sender: "@alice:example.com",
                body: "\(index)", ts: index * 1_000)
            let row = SDRoomEvent(
                roomId: roomId.value, eventId: event.eventId.value,
                ts: event.originServerTs, type: event.type,
                sender: event.sender.value,
                content: try JSONEncoder().encode(event.content), isMessageLike: true)
            row.room = room
            context.insert(row)
        }
        try context.save()

        let reader = TimelinePayloadReader(reader: MatrixStoreReader(modelContainer: container))
        let initial = try #require(await reader.timelinePayloadAround(
            roomId: roomId, anchorEventId: "$70", olderLimit: 49, newerLimit: 50))
        #expect(initial.snapshot.count == 100)
        #expect(initial.snapshot.first?.eventId.value == "$21")

        let older = try #require(await reader.timelinePayloadAround(
            roomId: roomId, anchorEventId: "$21", olderLimit: 50, newerLimit: 99))
        let back = TimelineViewModel.liveSlice(older.snapshot, keeping: .older)
        #expect(back.count == 100)
        #expect(back.first?.eventId.value == "$0")
        #expect(back.last?.eventId.value == "$99")
        #expect(older.snapshot.count > back.count)

        let newer = try #require(await reader.timelinePayloadAround(
            roomId: roomId, anchorEventId: "$99", olderLimit: 99, newerLimit: 50))
        let forward = TimelineViewModel.liveSlice(newer.snapshot, keeping: .newer)
        #expect(forward.count == 100)
        #expect(forward.first?.eventId.value == "$50")
        #expect(forward.last?.eventId.value == "$149")
        #expect(newer.snapshot.count > forward.count)
    }
}
