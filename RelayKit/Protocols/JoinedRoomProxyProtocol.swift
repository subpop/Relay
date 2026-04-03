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

// JoinedRoomProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A proxy for a room the user has joined.
///
/// Provides full access to room operations including messaging,
/// member management, timeline access, encryption state, and
/// room settings. All properties are observable and update in
/// response to sync events.
///
/// ## Reactive Room Info
///
/// Room metadata (name, topic, avatar, member counts, etc.) is
/// delivered via ``infoUpdates`` and reflected in observable properties.
/// SwiftUI views can bind directly to these properties.
///
/// ## Timeline Access
///
/// Call ``timeline()`` to obtain a ``TimelineProxyProtocol`` for
/// reading and sending messages in the room.
///
/// ## Topics
///
/// ### Identity
/// - ``id``
/// - ``displayName``
/// - ``topic``
/// - ``avatarURL``
///
/// ### Room State
/// - ``isDirect``
/// - ``isEncrypted``
/// - ``isSpace``
/// - ``membership``
///
/// ### Members
/// - ``members()``
/// - ``member(userId:)``
/// - ``invite(userId:)``
/// - ``kick(userId:reason:)``
/// - ``ban(userId:reason:)``
/// - ``unban(userId:reason:)``
///
/// ### Timeline
/// - ``timeline()``
///
/// ### Settings
/// - ``setName(_:)``
/// - ``setTopic(_:)``
/// - ``setFavourite(_:tagOrder:)``
public protocol JoinedRoomProxyProtocol: AnyObject, Sendable {
    // MARK: - Observable Properties

    /// The Matrix room ID (e.g. `!abc:matrix.org`).
    var id: String { get }

    /// The computed display name of the room.
    var displayName: String? { get }

    /// The room's topic, if set.
    var topic: String? { get }

    /// The room's avatar URL, if set.
    var avatarURL: URL? { get }

    /// Whether this is a direct message room.
    var isDirect: Bool { get }

    /// Whether the room is publicly joinable.
    var isPublic: Bool { get }

    /// Whether this room is a Matrix space.
    var isSpace: Bool { get }

    /// Whether end-to-end encryption is enabled.
    var isEncrypted: Bool { get }

    /// Whether the user has marked this room as a favourite.
    var isFavourite: Bool { get }

    /// Whether the user has marked this room as low priority.
    var isLowPriority: Bool { get }

    /// The user's current membership state.
    var membership: Membership { get }

    /// The number of active (joined + invited) members.
    var activeMemberCount: UInt64 { get }

    /// The number of joined members.
    var joinedMemberCount: UInt64 { get }

    /// The number of invited members.
    var invitedMemberCount: UInt64 { get }

    /// The number of highlighted (mentioned) unread events.
    var highlightCount: UInt64 { get }

    /// The number of unread notification events.
    var notificationCount: UInt64 { get }

    /// The IDs of pinned events in this room.
    var pinnedEventIDs: [String] { get }

    /// The room's heroes (used for display name/avatar computation).
    var heroes: [RoomHero] { get }

    /// The room's join rule.
    var joinRule: JoinRule? { get }

    /// The room's history visibility setting.
    var historyVisibility: RoomHistoryVisibility { get }

    // MARK: - Async Streams

    /// An async stream of room info updates.
    var infoUpdates: AsyncStream<RoomInfo> { get }

    /// An async stream of user IDs currently typing.
    var typingNotifications: AsyncStream<[String]> { get }

    /// An async stream of identity status changes for room members.
    var identityStatusChanges: AsyncStream<[IdentityStatusChange]> { get }

    /// An async stream of send queue state changes.
    var sendQueueUpdates: AsyncStream<RoomSendQueueUpdate> { get }

    /// An async stream of pending knock requests.
    var knockRequests: AsyncStream<[KnockRequest]> { get }

    /// An async stream of active live location shares.
    var liveLocationShares: AsyncStream<[LiveLocationShare]> { get }

    // MARK: - Timeline

    /// Returns the room's message timeline.
    ///
    /// - Returns: The timeline proxy.
    /// - Throws: If the timeline cannot be loaded.
    func timeline() async throws -> Timeline

    // MARK: - Members

    /// Fetches all room members.
    ///
    /// - Returns: An iterator over room members.
    /// - Throws: If the member list cannot be loaded.
    func members() async throws -> RoomMembersIterator

    /// Fetches a specific room member by user ID.
    ///
    /// - Parameter userId: The member's Matrix user ID.
    /// - Returns: The room member.
    /// - Throws: If the member is not found.
    func member(userId: String) async throws -> RoomMember

    /// Invites a user to the room.
    ///
    /// - Parameter userId: The user ID to invite.
    /// - Throws: If the invitation fails.
    func invite(userId: String) async throws

    /// Kicks a user from the room.
    ///
    /// - Parameters:
    ///   - userId: The user ID to kick.
    ///   - reason: An optional reason for the kick.
    /// - Throws: If the kick fails.
    func kick(userId: String, reason: String?) async throws

    /// Bans a user from the room.
    ///
    /// - Parameters:
    ///   - userId: The user ID to ban.
    ///   - reason: An optional reason for the ban.
    /// - Throws: If the ban fails.
    func ban(userId: String, reason: String?) async throws

    /// Unbans a user from the room.
    ///
    /// - Parameters:
    ///   - userId: The user ID to unban.
    ///   - reason: An optional reason for the unban.
    /// - Throws: If the unban fails.
    func unban(userId: String, reason: String?) async throws

    /// Leaves the room.
    ///
    /// - Throws: If leaving fails.
    func leave() async throws

    // MARK: - Room Settings

    /// Sets the room's name.
    ///
    /// - Parameter name: The new room name.
    /// - Throws: If the update fails.
    func setName(_ name: String) async throws

    /// Sets the room's topic.
    ///
    /// - Parameter topic: The new room topic.
    /// - Throws: If the update fails.
    func setTopic(_ topic: String) async throws

    /// Marks or unmarks the room as a favourite.
    ///
    /// - Parameters:
    ///   - isFavourite: Whether to favourite the room.
    ///   - tagOrder: An optional sort order for the favourite tag.
    /// - Throws: If the update fails.
    func setFavourite(_ isFavourite: Bool, tagOrder: Double?) async throws

    /// Marks or unmarks the room as low priority.
    ///
    /// - Parameters:
    ///   - isLowPriority: Whether to mark as low priority.
    ///   - tagOrder: An optional sort order for the low priority tag.
    /// - Throws: If the update fails.
    func setLowPriority(_ isLowPriority: Bool, tagOrder: Double?) async throws

    /// Sends a read receipt for the latest event.
    ///
    /// - Parameter receiptType: The type of read receipt to send.
    /// - Throws: If sending the receipt fails.
    func markAsRead(receiptType: ReceiptType) async throws

    /// Reports an event as inappropriate.
    ///
    /// - Parameters:
    ///   - eventId: The ID of the event to report.
    ///   - reason: An optional reason for the report.
    /// - Throws: If reporting fails.
    func reportContent(eventId: String, reason: String?) async throws

    /// Redacts (deletes) an event from the room.
    ///
    /// - Parameters:
    ///   - eventId: The ID of the event to redact.
    ///   - reason: An optional reason for the redaction.
    /// - Throws: If redaction fails.
    func redact(eventId: String, reason: String?) async throws

    // MARK: - Power Levels

    /// Returns the room's power level configuration.
    ///
    /// - Returns: The room power levels.
    /// - Throws: If the power levels cannot be loaded.
    func getPowerLevels() async throws -> RoomPowerLevels

    /// Applies changes to the room's power levels.
    ///
    /// - Parameter changes: The power level changes to apply.
    /// - Throws: If the update fails.
    func applyPowerLevelChanges(changes: RoomPowerLevelChanges) async throws

    // MARK: - Live Location

    /// Starts sharing live location for the given duration.
    ///
    /// - Parameter durationMillis: The sharing duration in milliseconds.
    /// - Throws: If starting fails.
    func startLiveLocationShare(durationMillis: UInt64) async throws

    /// Stops sharing live location.
    ///
    /// - Throws: If stopping fails.
    func stopLiveLocationShare() async throws

    // MARK: - Typing Notifications

    /// Sends a typing indicator to the room.
    ///
    /// - Parameter isTyping: Whether the user is currently typing.
    /// - Throws: If sending the notice fails.
    func sendTypingNotice(isTyping: Bool) async throws

    // MARK: - Latest Event

    /// Returns the most recent event in the room.
    ///
    /// This fetches the latest event from the SDK, which may be a
    /// remote synced event, an invite event, a locally-echoed event,
    /// or `nil` if the room has no events.
    ///
    /// - Returns: The latest event value.
    func latestEvent() async -> LatestEventValue

    // MARK: - Composer Draft

    /// Loads the saved message composer draft.
    ///
    /// - Parameter threadRoot: An optional thread root event ID.
    /// - Returns: The draft, or `nil` if none exists.
    /// - Throws: If loading fails.
    func loadComposerDraft(threadRoot: String?) async throws -> ComposerDraft?

    /// Saves a message composer draft.
    ///
    /// - Parameters:
    ///   - draft: The draft to save.
    ///   - threadRoot: An optional thread root event ID.
    /// - Throws: If saving fails.
    func saveComposerDraft(_ draft: ComposerDraft, threadRoot: String?) async throws

    /// Clears the saved message composer draft.
    ///
    /// - Parameter threadRoot: An optional thread root event ID.
    /// - Throws: If clearing fails.
    func clearComposerDraft(threadRoot: String?) async throws
}
