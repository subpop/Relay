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

// TimelineProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Controls a room's message timeline with reactive diff-based updates.
///
/// The timeline delivers changes as a stream of `TimelineDiff` arrays.
/// Use ``TimelineItemProvider`` to apply these diffs and maintain a
/// current array of timeline items for display in SwiftUI.
///
/// ## Sending Messages
///
/// Messages are sent via methods like ``send(msg:)`` and queued locally
/// before being transmitted to the homeserver. Media attachments return
/// a `SendAttachmentJoinHandle` for progress tracking and cancellation.
///
/// ## Pagination
///
/// Call ``paginateBackwards(numEvents:)`` or ``paginateForwards(numEvents:)``
/// to load more history. The ``backPaginationStatus`` stream reports loading status.
///
/// ## Topics
///
/// ### Reactive Updates
/// - ``timelineUpdates``
/// - ``backPaginationStatus``
///
/// ### Sending
/// - ``send(msg:)``
/// - ``sendReply(msg:eventId:)``
/// - ``edit(eventOrTransactionId:newContent:)``
///
/// ### Media
/// - ``sendImage(params:thumbnailSource:imageInfo:)``
/// - ``sendVideo(params:thumbnailSource:videoInfo:)``
/// - ``sendAudio(params:audioInfo:)``
/// - ``sendFile(params:fileInfo:)``
///
/// ### Pagination
/// - ``paginateBackwards(numEvents:)``
/// - ``paginateForwards(numEvents:)``
///
/// ### Reactions
/// - ``toggleReaction(itemId:key:)``
///
/// ### Moderation
/// - ``redactEvent(eventOrTransactionId:reason:)``
public protocol TimelineProxyProtocol: AnyObject, Sendable {
    // MARK: - Async Streams

    /// An async stream of timeline diff batches.
    ///
    /// Each value is an array of `TimelineDiff` operations that should
    /// be applied to the current timeline items array using ``DiffEngine``.
    var timelineUpdates: AsyncStream<[TimelineDiff]> { get }

    /// An async stream of backward pagination status changes.
    var backPaginationStatus: AsyncStream<PaginationStatus> { get }

    // MARK: - Sending Messages

    /// Sends a message to the room.
    ///
    /// - Parameter msg: The message content.
    /// - Returns: A handle to abort or retry the send.
    /// - Throws: If sending fails.
    func send(msg: RoomMessageEventContentWithoutRelation) async throws -> SendHandle

    /// Sends a reply to a specific event.
    ///
    /// - Parameters:
    ///   - msg: The reply content.
    ///   - eventId: The ID of the event being replied to.
    /// - Throws: If sending fails.
    func sendReply(msg: RoomMessageEventContentWithoutRelation, eventId: String) async throws

    /// Edits a previously sent message.
    ///
    /// - Parameters:
    ///   - eventOrTransactionId: The event or transaction ID of the message to edit.
    ///   - newContent: The new content for the message.
    /// - Throws: If editing fails.
    func edit(eventOrTransactionId: EventOrTransactionId, newContent: EditedContent) async throws

    /// Redacts (deletes) a timeline event.
    ///
    /// - Parameters:
    ///   - eventOrTransactionId: The event or transaction ID to redact.
    ///   - reason: An optional reason for the redaction.
    /// - Throws: If redaction fails.
    func redactEvent(eventOrTransactionId: EventOrTransactionId, reason: String?) async throws

    /// Toggles a reaction on a timeline event.
    ///
    /// - Parameters:
    ///   - itemId: The event or transaction ID to react to.
    ///   - key: The reaction key (e.g. an emoji).
    /// - Returns: `true` if the reaction was added, `false` if removed.
    /// - Throws: If toggling fails.
    func toggleReaction(itemId: EventOrTransactionId, key: String) async throws -> Bool

    // MARK: - Media

    /// Sends an image attachment.
    ///
    /// - Parameters:
    ///   - params: The upload parameters including source and caption.
    ///   - thumbnailSource: An optional thumbnail source.
    ///   - imageInfo: Metadata about the image.
    /// - Returns: A handle to join or cancel the upload.
    /// - Throws: If sending fails.
    func sendImage(
        params: UploadParameters,
        thumbnailSource: UploadSource?,
        imageInfo: ImageInfo
    ) throws -> SendAttachmentJoinHandle

    /// Sends a video attachment.
    ///
    /// - Parameters:
    ///   - params: The upload parameters.
    ///   - thumbnailSource: An optional thumbnail source.
    ///   - videoInfo: Metadata about the video.
    /// - Returns: A handle to join or cancel the upload.
    /// - Throws: If sending fails.
    func sendVideo(
        params: UploadParameters,
        thumbnailSource: UploadSource?,
        videoInfo: VideoInfo
    ) throws -> SendAttachmentJoinHandle

    /// Sends an audio attachment.
    ///
    /// - Parameters:
    ///   - params: The upload parameters.
    ///   - audioInfo: Metadata about the audio.
    /// - Returns: A handle to join or cancel the upload.
    /// - Throws: If sending fails.
    func sendAudio(params: UploadParameters, audioInfo: AudioInfo) throws -> SendAttachmentJoinHandle

    /// Sends a file attachment.
    ///
    /// - Parameters:
    ///   - params: The upload parameters.
    ///   - fileInfo: Metadata about the file.
    /// - Returns: A handle to join or cancel the upload.
    /// - Throws: If sending fails.
    func sendFile(params: UploadParameters, fileInfo: FileInfo) throws -> SendAttachmentJoinHandle

    /// Sends a voice message with waveform data.
    ///
    /// - Parameters:
    ///   - params: The upload parameters.
    ///   - audioInfo: Metadata about the audio.
    ///   - waveform: The audio waveform samples.
    /// - Returns: A handle to join or cancel the upload.
    /// - Throws: If sending fails.
    func sendVoiceMessage(
        params: UploadParameters,
        audioInfo: AudioInfo,
        waveform: [Float]
    ) throws -> SendAttachmentJoinHandle

    /// Sends a location message.
    ///
    /// - Parameters:
    ///   - body: The message body text.
    ///   - geoUri: The geographic URI (e.g. `geo:51.5,0.1`).
    ///   - description: An optional location description.
    ///   - zoomLevel: An optional map zoom level.
    ///   - assetType: An optional asset type.
    ///   - repliedToEventId: An optional event ID to reply to.
    /// - Throws: If sending fails.
    func sendLocation( // swiftlint:disable:this function_parameter_count
        body: String,
        geoUri: String,
        description: String?,
        zoomLevel: UInt8?,
        assetType: AssetType?,
        repliedToEventId: String?
    ) async throws

    // MARK: - Polls

    /// Creates a new poll.
    ///
    /// - Parameters:
    ///   - question: The poll question.
    ///   - answers: The available answers.
    ///   - maxSelections: Maximum number of answers a user can select.
    ///   - pollKind: The kind of poll (disclosed or undisclosed).
    /// - Throws: If creating the poll fails.
    func createPoll(question: String, answers: [String], maxSelections: UInt8, pollKind: PollKind) async throws

    /// Ends an active poll.
    ///
    /// - Parameters:
    ///   - pollStartEventId: The event ID of the poll start event.
    ///   - text: The closing text.
    /// - Throws: If ending the poll fails.
    func endPoll(pollStartEventId: String, text: String) async throws

    /// Sends a response to a poll.
    ///
    /// - Parameters:
    ///   - pollStartEventId: The event ID of the poll start event.
    ///   - answers: The selected answer IDs.
    /// - Throws: If sending the response fails.
    func sendPollResponse(pollStartEventId: String, answers: [String]) async throws

    // MARK: - Pagination

    /// Loads older timeline events.
    ///
    /// - Parameter numEvents: The number of events to load.
    /// - Returns: `true` if more events are available.
    /// - Throws: If pagination fails.
    func paginateBackwards(numEvents: UInt16) async throws -> Bool

    /// Loads newer timeline events.
    ///
    /// - Parameter numEvents: The number of events to load.
    /// - Returns: `true` if more events are available.
    /// - Throws: If pagination fails.
    func paginateForwards(numEvents: UInt16) async throws -> Bool

    // MARK: - Read Receipts

    /// Sends a read receipt for a specific event.
    ///
    /// - Parameters:
    ///   - receiptType: The type of receipt to send.
    ///   - eventId: The event ID to mark as read.
    /// - Throws: If sending the receipt fails.
    func sendReadReceipt(receiptType: ReceiptType, eventId: String) async throws

    // MARK: - Event Details

    /// Fetches full details for an event.
    ///
    /// - Parameter eventId: The event ID.
    /// - Throws: If fetching fails.
    func fetchDetailsForEvent(eventId: String) async throws

    /// Retries decryption for events encrypted with the given sessions.
    ///
    /// - Parameter sessionIds: The session IDs to retry.
    func retryDecryption(sessionIds: [String])

    /// Loads the details of the event being replied to.
    ///
    /// - Parameter eventIdStr: The event ID.
    /// - Returns: The reply details.
    /// - Throws: If loading fails.
    func loadReplyDetails(eventIdStr: String) async throws -> InReplyToDetails

    // MARK: - Pinning

    /// Pins an event in the room.
    ///
    /// - Parameter eventId: The event ID to pin.
    /// - Returns: `true` if the event was pinned.
    /// - Throws: If pinning fails.
    func pinEvent(eventId: String) async throws -> Bool

    /// Unpins an event from the room.
    ///
    /// - Parameter eventId: The event ID to unpin.
    /// - Returns: `true` if the event was unpinned.
    /// - Throws: If unpinning fails.
    func unpinEvent(eventId: String) async throws -> Bool
}
