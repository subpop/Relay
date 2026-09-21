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

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MatrixKit
import UniformTypeIdentifiers

/// View model driving `TimelineView` from an `ObservableRoom`.
///
/// Fresh instances are cheap (the room actor owns the window and the
/// observable timeline re-subscribes on init), so callers create one per
/// opened room instead of caching. Member shapes mirror the previous
/// view-model protocol to keep view churn minimal.
@Observable
final class TimelineViewModel {
    private let room: ObservableRoom
    private let errorReporter: ErrorReporter

    /// Whether the initial load is in flight.
    var isLoading = true
    /// First unread event ID for the "New" divider. Derived from the
    /// room's read marker (``fullyReadEventId`` is the *last read*
    /// event; this is the oldest message newer than it), so it stays
    /// current as receipts advance and clears when the room is read.
    var firstUnreadMessageId: String? { room.firstUnreadEventId?.value }
    /// Whether membership events render.
    var showMembershipEvents = true
    /// Whether other state events render.
    var showStateEvents = true

    /// The room ID.
    var roomId: String { room.roomId.value }
    /// The current user ID for outgoing detection.
    var currentUserId: String? { room.localUserId?.value }

    /// Rendered events, oldest first.
    var events: [ObservableTimelineEvent] {
        room.timeline?.events ?? []
    }

    /// View-facing alias for ``events``.
    var messages: [ObservableTimelineEvent] { events }

    /// Whether the room is a direct chat (drives media auto-reveal).
    var isDirectRoom: Bool { room.presentsAsDirect }

    /// The ID of the room that replaces this one, if tombstoned.
    var successorRoomId: String? { room.successorRoomId }

    /// Whether an event is currently pinned.
    func isPinned(eventId: String) -> Bool {
        room.pinnedEventIds.contains(eventId)
    }

    /// Members with role details, for mentions and profile taps.
    func roomMembers() async -> [RoomMemberDetails] {
        (try? await room.roomDetails())?.members ?? []
    }

    /// The local user's power-level-derived permissions.
    func roomPermissions() async -> RoomPermissions? {
        (try? await room.roomDetails())?.permissions
    }

    /// Send (or stop) a typing notification.
    func setTyping(_ typing: Bool) async {
        try? await room.setTyping(typing)
    }

    /// Pre-computed rows with grouping metadata.
    var messageRows: [MessageRow] {
        MessageRowBuilder.buildRows(
            for: filteredEvents,
            localUserId: room.localUserId,
            hasReachedStart: hasReachedStart)
    }

    /// Whether older messages are being fetched.
    var isLoadingMore: Bool { room.timeline?.isPaginating ?? false }

    /// Whether backward pagination reached the room start.
    var hasReachedStart: Bool { !(room.timeline?.hasMore ?? true) }

    /// Whether forward pagination reached the live edge (focus mode).
    var hasReachedEnd: Bool { room.timeline?.hasReachedEnd ?? true }

    /// Users currently typing, with display names.
    var typingUsers: [TypingUser] {
        room.typingUsers.map { userId in
            let details = room.memberDetails[userId]
            return TypingUser(
                id: userId.value,
                displayName: details?.displayname ?? userId.value,
                avatarURL: details?.avatarUrl)
        }
    }

    /// Whether the timeline shows live messages or a focused event.
    var timelineFocus: TimelineFocus { room.timeline?.timelineFocus ?? .live }

    init(room: ObservableRoom, highlights: [String] = [], errorReporter: ErrorReporter) {
        self.room = room
        self.errorReporter = errorReporter
        room.timeline?.highlightKeywords = highlights
    }

    // MARK: - State

    private var filteredEvents: [ObservableTimelineEvent] {
        events.filter { event in
            switch event.kind {
            case .state:
                return showStateEvents
            case .profileChange:
                return showMembershipEvents
            default:
                return true
            }
        }
    }

    /// Load the live timeline (already live from init; clears the
    /// loading gate and applies highlight keywords).
    func loadTimeline() async {
        isLoading = true
        if room.localUserId == nil {
            // Without a local user ID every message renders as incoming;
            // log it so the failure is observable instead of silent.
            ActivityLog.shared.log(
                category: .sync, severity: .warning, source: "TimelineViewModel",
                summary: "Local user ID unavailable; own messages render as incoming")
        }
        if room.timeline == nil {
            // ObservableRoom builds its timeline in init; this only
            // covers rooms constructed before the timeline existed.
            isLoading = false
            return
        }
        isLoading = false
    }

    /// Load a thread-scoped timeline for a thread root.
    func loadThreadTimeline(rootEventId: String) async {
        isLoading = true
        do {
            try await room.timeline?.loadThread(
                rootEventId: EventId(unchecked: rootEventId))
        } catch {
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
        }
        isLoading = false
    }

    /// Paginate backward to older history.
    func loadMoreHistory() async {
        try? await room.timeline?.loadMore()
    }

    /// Paginate forward toward the live edge (focus mode).
    func loadMoreFuture() async {
        try? await room.timeline?.loadMoreFuture()
    }

    /// Focus on one event with context around it.
    func focusOnEvent(eventId: String) async {
        do {
            try await room.timeline?.focus(eventId: EventId(unchecked: eventId))
        } catch {
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
        }
    }

    /// Return to the live timeline.
    func returnToLive() async {
        await room.timeline?.returnToLive()
    }

    /// Advance the fully-read marker (synced across devices).
    func sendFullyReadReceipt(upTo eventId: String) async {
        do {
            try await room.sendFullyRead(EventId(unchecked: eventId))
        } catch {
            ActivityLog.shared.log(
                category: .timeline, severity: .debug, source: "TimelineViewModel",
                summary: "Fully-read marker send failed",
                detail: error.localizedDescription,
                roomId: roomId)
        }
    }

    /// Update which system events render (read-only consumers ignore).
    func updateEventFiltering(showMembership: Bool, showState: Bool) {
        showMembershipEvents = showMembership
        showStateEvents = showState
    }

    // MARK: - Actions

    /// Send a text message, optionally as a reply with mentions.
    func send(text: String, inReplyTo eventId: String?, mentionedUserIds: [String]) async {
        let mentions = mentionsParam(mentionedUserIds)
        if let eventId {
            try? await room.reply(
                to: EventId(unchecked: eventId), text: text, mentions: mentions)
            return
        }
        _ = await room.send(text: text, mentions: mentions)
    }

    /// Send a file attachment with probed metadata.
    func sendAttachment(url: URL, caption: String?, inReplyTo: String?) async {
        let filename = url.lastPathComponent
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        let mimeType = utType.preferredMIMEType ?? "application/octet-stream"
        guard let data = try? Data(contentsOf: url) else {
            errorReporter.report(.fileCopyFailed(filename: filename, reason: "Unreadable file"))
            return
        }
        var width: Int?
        var height: Int?
        var duration: Int?
        var thumbnailData: Data?
        if utType.conforms(to: .image),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
            width = cgImage.width
            height = cgImage.height
            thumbnailData = jpegThumbnail(cgImage: cgImage, maxDimension: 800)
        } else if utType.conforms(to: .movie) || utType.conforms(to: .video)
            || utType.conforms(to: .audio)
        {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
                let size = try? await track.load(.naturalSize)
            {
                width = Int(size.width)
                height = Int(size.height)
            }
            if let durationSeconds = try? await asset.load(.duration).seconds,
                durationSeconds.isFinite
            {
                duration = Int(durationSeconds * 1000)
            }
        }
        _ = await room.sendAttachment(
            data: data, filename: filename, mimeType: mimeType,
            caption: caption, width: width, height: height, duration: duration,
            thumbnailData: thumbnailData, thumbnailMimeType: "image/jpeg",
            inReplyTo: inReplyTo.map(EventId.init(unchecked:)))
    }

    /// Toggle an emoji reaction (removes the user's own reaction if present).
    /// The badge updates optimistically; sync confirms in the background.
    func toggleReaction(messageId: String, key: String) async {
        await room.toggleReaction(
            target: EventId(unchecked: messageId), key: key)
    }

    /// Edit own message text.
    func edit(messageId: String, newText: String, mentionedUserIds: [String]) async {
        try? await room.edit(
            EventId(unchecked: messageId), newText: newText,
            mentions: mentionsParam(mentionedUserIds))
    }

    /// Redact a message (cancels unsent echoes).
    func redact(messageId: String, reason: String? = nil) async {
        try? await room.redact(EventId(unchecked: messageId), reason: reason)
    }

    /// Pin a message.
    func pin(eventId: String) async {
        do {
            try await room.pin(EventId(unchecked: eventId))
        } catch {
            errorReporter.report(.pinFailed(error.localizedDescription))
        }
    }

    /// Unpin a message.
    func unpin(eventId: String) async {
        do {
            try await room.unpin(EventId(unchecked: eventId))
        } catch {
            errorReporter.report(.pinFailed(error.localizedDescription))
        }
    }

    // MARK: - Private

    private func mentionsParam(_ userIds: [String]) -> Mentions? {
        guard !userIds.isEmpty else { return nil }
        return Mentions(userIds: userIds.map(UserId.init(unchecked:)))
    }

    /// Downscaled JPEG thumbnail for image attachments.
    private func jpegThumbnail(cgImage: CGImage, maxDimension: CGFloat) -> Data? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = CGSize(width: width * scale, height: height * scale)
        guard size.width >= 1, size.height >= 1,
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let thumbnail = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
