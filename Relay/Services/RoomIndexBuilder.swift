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
import OSLog
import SwiftData

private nonisolated let roomIndexSignposter = OSSignposter(
    subsystem: "app.subpop.Relay.performance", category: "RoomIndex")
/// Snapshot payload for one room's live timeline window. Sendable value,
/// produced off the main actor.
struct TimelinePayload: Sendable {
    var snapshot: [MessageEvent]
    var sendStates: [EventId: SendState]
    var firstUnreadEventId: String?
    var prevBatch: String?
    /// Set after a retention trim left `prevBatch` unable to reach the
    /// trimmed range: back-pagination resumes before this event via
    /// `/context` instead.
    var historyGapEventId: String? = nil
}

/// Background builder for store-backed UI snapshots.
///
/// Owns a private `ModelContext` confined to this actor: every fetch and
/// JSON decode here runs off the main thread, keeping sync bursts and
/// timeline refreshes from stalling UI on large stores (which keep full
/// event history). Callers receive finished `Sendable` values and assign
/// them on the main actor. Methods are suspension-free by construction
/// (fetch + decode + build only), so the confined context never crosses
/// a suspension point.
actor RoomIndexBuilder {
    private var context: ModelContext
    private let localUser: UserId?

    init(container: ModelContainer, localUser: UserId?) {
        context = ModelContext(container)
        self.localUser = localUser
    }

    /// Rebuild every room snapshot. Bounded queries only: full-table
    /// room/member/edge fetches (small tables) plus one newest-event and
    /// one newest-message row per room — never a full event-history scan.
    func rebuild() -> (
        joined: [RelayRoom], invited: [RelayRoom],
        spaceChildren: [RoomId: Set<RoomId>]
    ) {
        let state = roomIndexSignposter.beginInterval(
            "rebuildRoomIndex", id: roomIndexSignposter.makeSignpostID())
        let rooms = (try? context.fetch(FetchDescriptor<SDRoom>())) ?? []
        let allMembers = (try? context.fetch(FetchDescriptor<SDRoomMember>())) ?? []
        let membersByRoom = Dictionary(grouping: allMembers, by: \.roomId)
        let allEdges = (try? context.fetch(FetchDescriptor<SDRoomEdge>())) ?? []
        let spaceChildren = Self.spaceChildrenByParent(rows: rooms, edges: allEdges)
        var joined: [RelayRoom] = []
        var invited: [RelayRoom] = []
        joined.reserveCapacity(rooms.count)
        for row in rooms {
            let room = RelayClient.relayRoom(
                row: row,
                members: membersByRoom[row.roomId] ?? [],
                parentSpaceIds: Set(SDRoomEdge.parents(of: row.roomId, in: allEdges).map {
                    RoomId(unchecked: $0)
                }),
                newestEventId: newestEventId(roomId: row.roomId),
                newestMessage: newestMessage(roomId: row.roomId),
                localUser: localUser)
            if room.membership == .invite {
                invited.append(room)
            } else if room.membership == .join {
                joined.append(room)
            }
        }
        roomIndexSignposter.endInterval(
            "rebuildRoomIndex", state,
            "rooms \(rooms.count), members \(allMembers.count), edges \(allEdges.count)")
        return (joined, invited, spaceChildren)
    }

    /// Member details for compose and the inspector, built from the store
    /// without moving profile processing onto the main actor.
    func memberDetails(roomId: String) -> [RoomMemberDetails] {
        let state = roomIndexSignposter.beginInterval(
            "memberDetailsFromStore", id: roomIndexSignposter.makeSignpostID())
        let id = roomId
        guard let room = (try? context.fetch(
            FetchDescriptor<SDRoom>(predicate: #Predicate { $0.roomId == id })
        ))?.first else {
            roomIndexSignposter.endInterval("memberDetailsFromStore", state, "no room")
            return []
        }

        let rows = (try? context.fetch(SDRoomMember.membersDescriptor(roomId: id))) ?? []
        let decoder = JSONDecoder()
        let powerLevels = room.powerLevelsContent.flatMap {
            try? decoder.decode([String: AnyCodable].self, from: $0)
        }
        let createContent = room.createEventContent.flatMap {
            try? decoder.decode([String: AnyCodable].self, from: $0)
        }
        let creatorState: (creators: Set<UserId>, infinite: Bool)
        if let sender = room.createEventSender, let createContent {
            creatorState = RoomMemberDetails.creators(
                sender: UserId(unchecked: sender), createContent: createContent)
        } else {
            creatorState = ([], false)
        }

        let members = rows.compactMap { row -> RoomMemberDetails? in
            guard row.membership == Membership.join.rawValue
                    || row.membership == Membership.invite.rawValue
            else { return nil }

            let userId = UserId(unchecked: row.userId)
            let isCreator = creatorState.creators.contains(userId)
            let level: Int
            if creatorState.infinite && isCreator {
                level = .max
            } else if let powerLevels {
                level = RoomPermissions.powerLevel(of: userId, in: powerLevels)
            } else {
                level = 0
            }
            return RoomMemberDetails(
                userId: userId,
                displayName: row.displayname,
                avatarURL: row.avatarUrl.flatMap { try? MXCURI($0) },
                role: .of(level),
                powerLevel: level,
                isCreator: isCreator)
        }.sorted {
            ($0.displayName ?? $0.userId.value)
                < ($1.displayName ?? $1.userId.value)
        }

        roomIndexSignposter.endInterval(
            "memberDetailsFromStore", state, "members \(members.count)")
        return members
    }

    /// Stored membership/profile map for timeline rendering fallbacks.
    func memberMap(roomId: String) -> [UserId: MemberContent] {
        let id = roomId
        let rows = (try? context.fetch(SDRoomMember.membersDescriptor(roomId: id))) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (
                UserId(unchecked: row.userId),
                MemberContent(
                    membership: Membership(rawValue: row.membership) ?? .join,
                    displayname: row.displayname,
                    avatarUrl: row.avatarUrl)
            )
        })
    }

    /// Parent-to-children map for space filtering: synced state edges
    /// in both directions, plus fetched hierarchy blobs (which cover
    /// unjoined branches whose state never syncs). Pure over rows for
    /// testing.
    static func spaceChildrenByParent(
        rows: [SDRoom], edges: [SDRoomEdge]
    ) -> [RoomId: Set<RoomId>] {
        var owners = Set(rows.map(\.roomId))
        for edge in edges {
            owners.insert(edge.ownerRoomId)
            owners.insert(edge.peerRoomId)
        }
        var children: [RoomId: Set<RoomId>] = [:]
        for owner in owners {
            let ids = SDRoomEdge.children(of: owner, in: edges)
                .map { RoomId(unchecked: $0) }
            if !ids.isEmpty {
                children[RoomId(unchecked: owner)] = Set(ids)
            }
        }
        for row in rows {
            let owner = RoomId(unchecked: row.roomId)
            for child in row.decodedHierarchyChildren() {
                children[owner, default: []].insert(child.roomId)
                for grandchild in child.childIds {
                    children[child.roomId, default: []].insert(grandchild)
                }
            }
        }
        return children
    }

    /// Live-window payload for one room: the newest window of events
    /// (oldest first), delivery states read off the same rows (no extra
    /// query), and the room's marker/cursor columns.
    func timelinePayload(roomId: String, limit: Int) -> TimelinePayload {
        let state = roomIndexSignposter.beginInterval(
            "fetchTimelinePayload", id: roomIndexSignposter.makeSignpostID(),
            "limit \(limit)")
        let rows = windowRows(roomId: roomId, limit: limit)
        let decoder = JSONDecoder()
        var snapshot: [MessageEvent] = []
        snapshot.reserveCapacity(rows.count)
        var sendStates: [EventId: SendState] = [:]
        for row in rows {
            if let event = row.messageEvent(decoder: decoder) {
                snapshot.append(event)
            }
            switch row.sendState {
            case "pending":
                sendStates[EventId(unchecked: row.eventId)] = .pending
            case "failed":
                sendStates[EventId(unchecked: row.eventId)] = .failed(
                    row.sendFailureReason ?? "Send failed")
            default:
                break
            }
        }
        let marker = markerSummary(roomId: roomId)
        let payload = TimelinePayload(
            snapshot: snapshot,
            sendStates: sendStates,
            firstUnreadEventId: marker.firstUnreadEventId,
            prevBatch: marker.prevBatch,
            historyGapEventId: marker.historyGapEventId)
        roomIndexSignposter.endInterval(
            "fetchTimelinePayload", state, "stored rows \(rows.count)")
        return payload
    }

    /// Marker and pagination-cursor columns for one room (single indexed
    /// row fetch, for detached windows that don't need the event window).
    func markerSummary(roomId: String) -> (
        firstUnreadEventId: String?, prevBatch: String?, historyGapEventId: String?
    ) {
        let id = roomId
        let row = try? context.fetch(FetchDescriptor<SDRoom>(
            predicate: #Predicate { $0.roomId == id })).first
        return (row?.firstUnreadEventId, row?.prevBatch, row?.historyGapEventId)
    }

    // MARK: - Private

    /// Newest stored event rows for a room, newest first (bounded).
    private func newestRows(
        roomId: String, messageLikeOnly: Bool, limit: Int
    ) -> [SDRoomEvent] {
        let id = roomId
        var descriptor: FetchDescriptor<SDRoomEvent>
        if messageLikeOnly {
            descriptor = FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.roomId == id && $0.isMessageLike },
                sortBy: [SortDescriptor(\.ts, order: .reverse)])
        } else {
            descriptor = FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.roomId == id },
                sortBy: [SortDescriptor(\.ts, order: .reverse)])
        }
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Newest stored event ID for optimistic-read checks.
    private func newestEventId(roomId: String) -> String? {
        newestRows(roomId: roomId, messageLikeOnly: false, limit: 1).first?.eventId
    }

    /// The local user's stored reaction event for a target+key, if any.
    /// Reactions are few per room, so the type-filtered scan stays
    /// cheap; it still runs off-main with everything else here.
    func ownReactionEvent(
        roomId: String, target: EventId, key: String, sender: UserId
    ) -> EventId? {
        let id = roomId
        let reaction = EventType.reaction.rawValue
        let rows = (try? context.fetch(FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate { $0.roomId == id && $0.type == reaction }))) ?? []
        let decoder = JSONDecoder()
        let events = rows.compactMap { $0.messageEvent(decoder: decoder) }
        return events.reactionEvent(target: target, key: key, sender: sender)
    }

    /// Newest message-like event for list previews.
    private func newestMessage(roomId: String) -> MessageEvent? {
        let decoder = JSONDecoder()
        for row in newestRows(roomId: roomId, messageLikeOnly: true, limit: 1) {
            if let event = row.messageEvent(decoder: decoder) {
                return event
            }
        }
        return nil
    }

    /// Newest window of stored events, oldest first (mirrors
    /// `MatrixStoreReader.timeline(_:limit:)`).
    private func windowRows(roomId: String, limit: Int) -> [SDRoomEvent] {
        Array(newestRows(roomId: roomId, messageLikeOnly: false, limit: limit).reversed())
    }
}
