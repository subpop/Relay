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

/// UI-only preview fixtures. Static value types only — never a live
/// server, keychain, or `MatrixClient`.
enum PreviewFixtures {
    /// Sample sidebar rooms covering the main visual states.
    static let rooms: [RoomRowData] = [
        RoomRowData(
            roomId: "!general:example.com",
            name: "General",
            topic: "Watercooler chat",
            canonicalAlias: "#general:example.com",
            parentSpaceIds: ["!space:example.com"],
            lastMessage: "Has anyone seen the release notes?",
            lastMessageAuthor: "Alice",
            lastMessageTimestamp: Date.now.addingTimeInterval(-300),
            notificationCount: 3,
            highlightCount: 0,
            isDirect: false,
            isMuted: false,
            isFavourite: true,
            isSpace: false,
            isArchived: false),
        RoomRowData(
            roomId: "!dm:example.com",
            name: "Ada Lovelace",
            lastMessage: "@relay please review the timeline diff",
            lastMessageAuthor: "Ada Lovelace",
            lastMessageTimestamp: Date.now.addingTimeInterval(-3600),
            notificationCount: 1,
            highlightCount: 1,
            isDirect: true,
            isMuted: false,
            isFavourite: false,
            isSpace: false,
            isArchived: false),
        RoomRowData(
            roomId: "!quiet:example.com",
            name: "Muted announcements",
            lastMessage: "Scheduled maintenance Sunday",
            lastMessageAuthor: "Ops",
            lastMessageTimestamp: Date.now.addingTimeInterval(-86400),
            notificationCount: 12,
            highlightCount: 0,
            isDirect: false,
            isMuted: true,
            isFavourite: false,
            isSpace: false,
            isArchived: false),
        RoomRowData(
            roomId: "!space:example.com",
            name: "Engineering",
            lastMessageTimestamp: nil,
            notificationCount: 0,
            highlightCount: 0,
            isDirect: false,
            isMuted: false,
            isFavourite: false,
            isSpace: true,
            isArchived: false),
        RoomRowData(
            roomId: "!dev:example.com",
            name: "Development",
            lastMessage: "Merged the refactor PR",
            lastMessageAuthor: "Alice",
            lastMessageTimestamp: Date.now.addingTimeInterval(-600),
            notificationCount: 5,
            highlightCount: 2,
            isDirect: false,
            isMuted: false,
            isFavourite: false,
            isSpace: false,
            isArchived: false),
    ]

    /// A sample invite row.
    static let invite = InviteRowData(
        roomId: "!invited:example.com",
        name: "Secret project",
        topic: "Classified watercooler",
        inviterName: "Grace Hopper",
        inviterAvatarURL: nil)

    /// A logged-out client (default state).
    static let loggedOutClient: RelayClient = {
        let client = RelayClient()
        client.authState = .loggedOut
        return client
    }()

    /// A client showing the offline banner (no network path).
    static let offlineClient: RelayClient = {
        let client = RelayClient()
        client.authState = .loggedIn(userId: "@preview:example.com")
        client.syncState = .offline
        client.isNetworkConnected = false
        return client
    }()

    /// A client showing the offline banner (homeserver unreachable).
    static let serverUnreachableClient: RelayClient = {
        let client = RelayClient()
        client.authState = .loggedIn(userId: "@preview:example.com")
        client.syncState = .offline
        client.isNetworkConnected = true
        return client
    }()

    /// A client with an unverified session.
    static let unverifiedClient: RelayClient = {
        let client = RelayClient()
        client.authState = .loggedIn(userId: "@preview:example.com")
        client.hasCheckedVerificationState = true
        client.isSessionVerified = false
        return client
    }()

    /// A client with a pending incoming verification request.
    static let incomingVerificationClient: RelayClient = {
        let client = RelayClient()
        client.authState = .loggedIn(userId: "@preview:example.com")
        client.hasCheckedVerificationState = true
        client.isSessionVerified = false
        client.pendingVerificationRequest = RelayClient.IncomingVerification(
            flowId: "preview-flow",
            deviceId: "ABCDEF1234",
            senderId: "@alice:example.com")
        return client
    }()

    /// A client with a background key-backup restore reporting
    /// determinate progress.
    static let restoringClient: RelayClient = {
        let client = RelayClient()
        client.authState = .loggedIn(userId: "@preview:example.com")
        client.keyFetch.tasks = [
            KeyFetchTask(
                title: "Restoring message history",
                completed: 120,
                total: 480,
                fraction: 0.25,
                task: Task {}),
        ]
        return client
    }()

    /// A client with a background key-backup restore whose total is
    /// still unknown (indeterminate progress).
    static let restoringIndeterminateClient: RelayClient = {
        let client = RelayClient()
        client.authState = .loggedIn(userId: "@preview:example.com")
        client.keyFetch.tasks = [
            KeyFetchTask(title: "Restoring message history", task: Task {}),
        ]
        return client
    }()

    // MARK: - Timeline events

    /// Builds an `ObservableTimelineEvent` for SwiftUI previews.
    ///
    /// - Parameters:
    ///   - id: Stable event ID suffix (prefixed with `$preview-`).
    ///   - sender: Full sender user ID.
    ///   - displayName: Sender display name.
    ///   - body: Plain-text body (also used as the media filename).
    ///   - kind: Explicit kind; defaults to `.text(body:)`.
    ///   - minutesAgo: Age of the event.
    ///   - reactions: Emoji key → sender IDs.
    ///   - ownReactions: Keys the preview user added.
    ///   - isHighlighted: Whether the event renders highlighted.
    ///   - reply: Resolved reply target.
    ///   - isEdited: Whether the event shows the edited indicator.
    ///   - sendState: Local delivery state (e.g. `.failed` for failure previews).
    @MainActor
    static func event(
        _ id: String,
        sender: String,
        displayName: String? = nil,
        body: String,
        kind: MessageKind? = nil,
        minutesAgo: Double = 5,
        formattedBody: String? = nil,
        reactions: [String: [String]] = [:],
        ownReactions: Set<String> = [],
        isHighlighted: Bool = false,
        reply: ResolvedReply? = nil,
        isEdited: Bool = false,
        sendState: SendState? = nil,
        targetUserId: String? = nil,
        targetDisplayName: String? = nil
    ) -> ObservableTimelineEvent {
        let event = ObservableTimelineEvent(
            eventId: EventId(unchecked: "$preview-\(id)"),
            sender: UserId(unchecked: sender),
            timestamp: .now.addingTimeInterval(-minutesAgo * 60),
            kind: kind ?? .text(body: body),
            reactions: Dictionary(
                uniqueKeysWithValues: reactions.map { key, senders in
                    (key, senders.map { UserId(unchecked: $0) })
                }),
            formattedBody: formattedBody,
            senderDisplayName: displayName,
            targetUserId: targetUserId.map { UserId(unchecked: $0) },
            targetDisplayName: targetDisplayName
        )
        event.ownReactions = ownReactions
        event.isHighlighted = isHighlighted
        event.reply = reply
        event.isEdited = isEdited
        event.sendState = sendState
        return event
    }

    /// Builds a `ResolvedReply` for SwiftUI previews.
    static func reply(
        _ id: String,
        sender: String,
        displayName: String? = nil,
        body: String,
        imageURL: String? = nil
    ) -> ResolvedReply {
        ResolvedReply(
            eventID: EventId(unchecked: "$preview-\(id)"),
            senderID: UserId(unchecked: sender),
            senderDisplayName: displayName,
            body: body,
            imageURL: imageURL
        )
    }
}
