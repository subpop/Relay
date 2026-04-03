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

// TimelineProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// An `@Observable` proxy that wraps the Matrix SDK `Timeline`.
///
/// Provides reactive timeline diff updates and all send/pagination
/// operations. Subscribe to ``timelineUpdates`` to receive diffs
/// and apply them via ``DiffEngine``.
@Observable
public final class TimelineProxy: TimelineProxyProtocol, @unchecked Sendable {
    private let timeline: Timeline
    @ObservationIgnored nonisolated(unsafe) private var listenerTaskHandle: TaskHandle?
    @ObservationIgnored nonisolated(unsafe) private var paginationTaskHandle: TaskHandle?

    /// An async stream of timeline diff batches.
    public let timelineUpdates: AsyncStream<[TimelineDiff]>
    private let timelineUpdatesContinuation: AsyncStream<[TimelineDiff]>.Continuation

    /// An async stream of backward pagination status changes.
    public let backPaginationStatus: AsyncStream<PaginationStatus>
    private let backPaginationStatusContinuation: AsyncStream<PaginationStatus>.Continuation

    /// Creates a timeline proxy.
    ///
    /// - Parameter timeline: The SDK timeline instance.
    public init(timeline: Timeline) {
        self.timeline = timeline

        let (timelineStream, timelineContinuation) = AsyncStream<[TimelineDiff]>.makeStream(
            bufferingPolicy: .bufferingNewest(100)
        )
        self.timelineUpdates = timelineStream
        self.timelineUpdatesContinuation = timelineContinuation

        let (pagStream, pagContinuation) = AsyncStream<PaginationStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.backPaginationStatus = pagStream
        self.backPaginationStatusContinuation = pagContinuation
    }

    /// Starts listening for timeline and pagination updates.
    ///
    /// Call this after initialization to begin receiving diffs.
    public func startListening() async throws {
        listenerTaskHandle = await timeline.addListener(
            listener: SDKListener { [weak self] diffs in
                self?.timelineUpdatesContinuation.yield(diffs)
            }
        )

        paginationTaskHandle = try await timeline.subscribeToBackPaginationStatus(
            listener: SDKListener { [weak self] status in
                self?.backPaginationStatusContinuation.yield(status)
            }
        )
    }

    deinit {
        listenerTaskHandle?.cancel()
        paginationTaskHandle?.cancel()
        timelineUpdatesContinuation.finish()
        backPaginationStatusContinuation.finish()
    }

    // MARK: - Sending Messages

    public func send(msg: RoomMessageEventContentWithoutRelation) async throws -> SendHandle {
        try await timeline.send(msg: msg)
    }

    public func sendReply(msg: RoomMessageEventContentWithoutRelation, eventId: String) async throws {
        try await timeline.sendReply(msg: msg, eventId: eventId)
    }

    public func edit(eventOrTransactionId: EventOrTransactionId, newContent: EditedContent) async throws {
        try await timeline.edit(eventOrTransactionId: eventOrTransactionId, newContent: newContent)
    }

    public func redactEvent(eventOrTransactionId: EventOrTransactionId, reason: String?) async throws {
        try await timeline.redactEvent(eventOrTransactionId: eventOrTransactionId, reason: reason)
    }

    public func toggleReaction(itemId: EventOrTransactionId, key: String) async throws -> Bool {
        try await timeline.toggleReaction(itemId: itemId, key: key)
    }

    // MARK: - Media

    public func sendImage(params: UploadParameters, thumbnailSource: UploadSource?, imageInfo: ImageInfo) throws -> SendAttachmentJoinHandle {
        try timeline.sendImage(params: params, thumbnailSource: thumbnailSource, imageInfo: imageInfo)
    }

    public func sendVideo(params: UploadParameters, thumbnailSource: UploadSource?, videoInfo: VideoInfo) throws -> SendAttachmentJoinHandle {
        try timeline.sendVideo(params: params, thumbnailSource: thumbnailSource, videoInfo: videoInfo)
    }

    public func sendAudio(params: UploadParameters, audioInfo: AudioInfo) throws -> SendAttachmentJoinHandle {
        try timeline.sendAudio(params: params, audioInfo: audioInfo)
    }

    public func sendFile(params: UploadParameters, fileInfo: FileInfo) throws -> SendAttachmentJoinHandle {
        try timeline.sendFile(params: params, fileInfo: fileInfo)
    }

    public func sendVoiceMessage(params: UploadParameters, audioInfo: AudioInfo, waveform: [Float]) throws -> SendAttachmentJoinHandle {
        try timeline.sendVoiceMessage(params: params, audioInfo: audioInfo, waveform: waveform)
    }

    public func sendLocation(body: String, geoUri: String, description: String?, zoomLevel: UInt8?, assetType: AssetType?, repliedToEventId: String?) async throws {
        try await timeline.sendLocation(body: body, geoUri: geoUri, description: description, zoomLevel: zoomLevel, assetType: assetType, repliedToEventId: repliedToEventId)
    }

    // MARK: - Polls

    public func createPoll(question: String, answers: [String], maxSelections: UInt8, pollKind: PollKind) async throws {
        try await timeline.createPoll(question: question, answers: answers, maxSelections: maxSelections, pollKind: pollKind)
    }

    public func endPoll(pollStartEventId: String, text: String) async throws {
        try await timeline.endPoll(pollStartEventId: pollStartEventId, text: text)
    }

    public func sendPollResponse(pollStartEventId: String, answers: [String]) async throws {
        try await timeline.sendPollResponse(pollStartEventId: pollStartEventId, answers: answers)
    }

    // MARK: - Pagination

    public func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        try await timeline.paginateBackwards(numEvents: numEvents)
    }

    public func paginateForwards(numEvents: UInt16) async throws -> Bool {
        try await timeline.paginateForwards(numEvents: numEvents)
    }

    // MARK: - Read Receipts

    public func sendReadReceipt(receiptType: ReceiptType, eventId: String) async throws {
        try await timeline.sendReadReceipt(receiptType: receiptType, eventId: eventId)
    }

    // MARK: - Event Details

    public func fetchDetailsForEvent(eventId: String) async throws {
        try await timeline.fetchDetailsForEvent(eventId: eventId)
    }

    public func retryDecryption(sessionIds: [String]) {
        timeline.retryDecryption(sessionIds: sessionIds)
    }

    public func loadReplyDetails(eventIdStr: String) async throws -> InReplyToDetails {
        try await timeline.loadReplyDetails(eventIdStr: eventIdStr)
    }

    // MARK: - Pinning

    public func pinEvent(eventId: String) async throws -> Bool {
        try await timeline.pinEvent(eventId: eventId)
    }

    public func unpinEvent(eventId: String) async throws -> Bool {
        try await timeline.unpinEvent(eventId: eventId)
    }
}
