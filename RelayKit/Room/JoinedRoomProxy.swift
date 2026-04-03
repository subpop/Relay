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

// JoinedRoomProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// An `@Observable` proxy for a room the user has joined.
///
/// Provides full access to room operations and reactive room info updates.
/// All properties update automatically from room info listener callbacks.
@Observable
public final class JoinedRoomProxy: JoinedRoomProxyProtocol, @unchecked Sendable {
    private let room: Room
    @ObservationIgnored nonisolated(unsafe) private var roomInfoTaskHandle: TaskHandle?
    @ObservationIgnored nonisolated(unsafe) private var typingTaskHandle: TaskHandle?

    // MARK: - Observable Properties

    public private(set) var id: String
    public private(set) var displayName: String?
    public private(set) var topic: String?
    public private(set) var avatarURL: URL?
    public private(set) var isDirect: Bool = false
    public private(set) var isPublic: Bool = false
    public private(set) var isSpace: Bool = false
    public private(set) var isEncrypted: Bool = false
    public private(set) var isFavourite: Bool = false
    public private(set) var isLowPriority: Bool = false
    public private(set) var membership: Membership = .joined
    public private(set) var activeMemberCount: UInt64 = 0
    public private(set) var joinedMemberCount: UInt64 = 0
    public private(set) var invitedMemberCount: UInt64 = 0
    public private(set) var highlightCount: UInt64 = 0
    public private(set) var notificationCount: UInt64 = 0
    public private(set) var pinnedEventIDs: [String] = []
    public private(set) var heroes: [RoomHero] = []
    public private(set) var joinRule: JoinRule?
    public private(set) var historyVisibility: RoomHistoryVisibility = .shared

    // MARK: - Async Streams

    public let infoUpdates: AsyncStream<RoomInfo>
    private let infoUpdatesContinuation: AsyncStream<RoomInfo>.Continuation

    public let typingNotifications: AsyncStream<[String]>
    private let typingNotificationsContinuation: AsyncStream<[String]>.Continuation

    public let identityStatusChanges: AsyncStream<[IdentityStatusChange]>
    private let identityStatusChangesContinuation: AsyncStream<[IdentityStatusChange]>.Continuation

    public let sendQueueUpdates: AsyncStream<RoomSendQueueUpdate>
    private let sendQueueUpdatesContinuation: AsyncStream<RoomSendQueueUpdate>.Continuation

    public let knockRequests: AsyncStream<[KnockRequest]>
    private let knockRequestsContinuation: AsyncStream<[KnockRequest]>.Continuation

    public let liveLocationShares: AsyncStream<[LiveLocationShare]>
    private let liveLocationSharesContinuation: AsyncStream<[LiveLocationShare]>.Continuation

    // MARK: - Initialization

    /// Creates a joined room proxy.
    ///
    /// - Parameter room: The SDK room instance.
    public init(room: Room) {
        self.room = room
        self.id = room.id()
        self.displayName = room.displayName()
        self.topic = room.topic()
        self.avatarURL = room.avatarUrl().matrixURL
        self.isSpace = room.isSpace()

        // Set up async streams
        let (infoStream, infoContinuation) = AsyncStream<RoomInfo>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.infoUpdates = infoStream
        self.infoUpdatesContinuation = infoContinuation

        let (typingStream, typingCont) = AsyncStream<[String]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.typingNotifications = typingStream
        self.typingNotificationsContinuation = typingCont

        let (identityStream, identityCont) = AsyncStream<[IdentityStatusChange]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.identityStatusChanges = identityStream
        self.identityStatusChangesContinuation = identityCont

        let (sqStream, sqCont) = AsyncStream<RoomSendQueueUpdate>.makeStream(bufferingPolicy: .bufferingNewest(10))
        self.sendQueueUpdates = sqStream
        self.sendQueueUpdatesContinuation = sqCont

        let (knockStream, knockCont) = AsyncStream<[KnockRequest]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.knockRequests = knockStream
        self.knockRequestsContinuation = knockCont

        let (llStream, llCont) = AsyncStream<[LiveLocationShare]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.liveLocationShares = llStream
        self.liveLocationSharesContinuation = llCont

        // Subscribe to room info updates
        roomInfoTaskHandle = room.subscribeToRoomInfoUpdates(listener: SDKListener { [weak self] roomInfo in
            Task { @MainActor in self?.applyRoomInfo(roomInfo) }
            infoContinuation.yield(roomInfo)
        })

        let typingContinuation = typingNotificationsContinuation
        typingTaskHandle = room.subscribeToTypingNotifications(listener: SDKListener { userIds in
            typingContinuation.yield(userIds)
        })
    }

    deinit {
        roomInfoTaskHandle?.cancel()
        typingTaskHandle?.cancel()
        infoUpdatesContinuation.finish()
        typingNotificationsContinuation.finish()
        identityStatusChangesContinuation.finish()
        sendQueueUpdatesContinuation.finish()
        knockRequestsContinuation.finish()
        liveLocationSharesContinuation.finish()
    }

    private func applyRoomInfo(_ info: RoomInfo) {
        displayName = info.displayName
        topic = info.topic
        avatarURL = info.avatarUrl.matrixURL
        isDirect = info.isDirect
        isPublic = info.isPublic ?? false
        isSpace = info.isSpace
        isEncrypted = info.encryptionState != .notEncrypted
        isFavourite = info.isFavourite
        isLowPriority = info.isLowPriority
        membership = info.membership
        activeMemberCount = info.activeMembersCount
        joinedMemberCount = info.joinedMembersCount
        invitedMemberCount = info.invitedMembersCount
        highlightCount = info.highlightCount
        notificationCount = info.notificationCount
        pinnedEventIDs = info.pinnedEventIds
        heroes = info.heroes
        joinRule = info.joinRule
        historyVisibility = info.historyVisibility
    }

    // MARK: - Timeline

    public func timeline() async throws -> Timeline {
        try await room.timeline()
    }

    // MARK: - Members

    public func members() async throws -> RoomMembersIterator {
        try await room.members()
    }

    public func member(userId: String) async throws -> RoomMember {
        try await room.member(userId: userId)
    }

    public func invite(userId: String) async throws {
        try await room.inviteUserById(userId: userId)
    }

    public func kick(userId: String, reason: String?) async throws {
        try await room.kickUser(userId: userId, reason: reason)
    }

    public func ban(userId: String, reason: String?) async throws {
        try await room.banUser(userId: userId, reason: reason)
    }

    public func unban(userId: String, reason: String?) async throws {
        try await room.unbanUser(userId: userId, reason: reason)
    }

    public func leave() async throws {
        try await room.leave()
    }

    // MARK: - Room Settings

    public func setName(_ name: String) async throws {
        try await room.setName(name: name)
    }

    public func setTopic(_ topic: String) async throws {
        try await room.setTopic(topic: topic)
    }

    public func setFavourite(_ isFavourite: Bool, tagOrder: Double?) async throws {
        try await room.setIsFavourite(isFavourite: isFavourite, tagOrder: tagOrder)
    }

    public func setLowPriority(_ isLowPriority: Bool, tagOrder: Double?) async throws {
        try await room.setIsLowPriority(isLowPriority: isLowPriority, tagOrder: tagOrder)
    }

    public func markAsRead(receiptType: ReceiptType) async throws {
        try await room.markAsRead(receiptType: receiptType)
    }

    public func reportContent(eventId: String, reason: String?) async throws {
        try await room.reportContent(eventId: eventId, reason: reason)
    }

    public func redact(eventId: String, reason: String?) async throws {
        try await room.redact(eventId: eventId, reason: reason)
    }

    // MARK: - Power Levels

    public func getPowerLevels() async throws -> RoomPowerLevels {
        try await room.getPowerLevels()
    }

    public func applyPowerLevelChanges(changes: RoomPowerLevelChanges) async throws {
        try await room.applyPowerLevelChanges(changes: changes)
    }

    // MARK: - Live Location

    public func startLiveLocationShare(durationMillis: UInt64) async throws {
        try await room.startLiveLocationShare(durationMillis: durationMillis)
    }

    public func stopLiveLocationShare() async throws {
        try await room.stopLiveLocationShare()
    }

    // MARK: - Typing Notifications

    public func sendTypingNotice(isTyping: Bool) async throws {
        try await room.typingNotice(isTyping: isTyping)
    }

    // MARK: - Latest Event

    public func latestEvent() async -> LatestEventValue {
        await room.latestEvent()
    }

    // MARK: - Composer Draft

    public func loadComposerDraft(threadRoot: String?) async throws -> ComposerDraft? {
        try await room.loadComposerDraft(threadRoot: threadRoot)
    }

    public func saveComposerDraft(_ draft: ComposerDraft, threadRoot: String?) async throws {
        try await room.saveComposerDraft(draft: draft, threadRoot: threadRoot)
    }

    public func clearComposerDraft(threadRoot: String?) async throws {
        try await room.clearComposerDraft(threadRoot: threadRoot)
    }
}
