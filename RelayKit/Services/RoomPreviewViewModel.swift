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

// RoomPreviewViewModel.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import RelayInterface
import os

private let logger = Logger(subsystem: "RelayKit", category: "RoomPreviewViewModel")

/// Concrete implementation of ``RoomPreviewViewModelProtocol`` backed by the Matrix Rust SDK.
///
/// ``RoomPreviewViewModel`` fetches a room preview from the homeserver and,
/// when the room has world-readable history, loads a read-only timeline of
/// recent messages. This allows users to browse a room before committing to
/// membership.
@Observable
public final class RoomPreviewViewModel: RoomPreviewViewModelProtocol {
    public private(set) var roomName: String?
    public private(set) var roomTopic: String?
    public private(set) var roomAvatarURL: String?
    public private(set) var memberCount: UInt64 = 0
    public private(set) var canonicalAlias: String?
    public private(set) var messages: [TimelineMessage] = []
    public private(set) var isLoading = false
    public let roomId: String

    private let client: any ClientProxyProtocol
    private var previewProxy: RoomPreviewProxy?
    private let messageMapper: TimelineMessageMapper
    private let errorReporter: ErrorReporter
    private var timelineItems: [TimelineItem] = []
    @ObservationIgnored private var timelineHandle: TaskHandle?
    private var observationTask: Task<Void, Never>?

    /// Creates a room preview view model.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room ID to preview.
    ///   - client: The authenticated client proxy.
    public init(roomId: String, client: any ClientProxyProtocol, errorReporter: ErrorReporter) {
        self.roomId = roomId
        self.client = client
        self.messageMapper = TimelineMessageMapper(currentUserId: client.userID)
        self.errorReporter = errorReporter
    }

    deinit {
        let task = MainActor.assumeIsolated { observationTask }
        task?.cancel()
    }

    public func loadPreview() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            let preview: RoomPreview
            if roomId.hasPrefix("#") {
                preview = try await client.getRoomPreviewFromRoomAlias(roomAlias: roomId)
            } else {
                preview = try await client.getRoomPreviewFromRoomId(
                    roomId: roomId,
                    viaServers: []
                )
            }
            let proxy = RoomPreviewProxy(preview: preview)
            self.previewProxy = proxy

            // Populate room metadata from the preview info.
            let info = proxy.info()
            roomName = info.name
            roomTopic = info.topic
            roomAvatarURL = info.avatarUrl
            memberCount = info.numJoinedMembers
            canonicalAlias = info.canonicalAlias

            // Attempt to load a read-only timeline if history is world-readable.
            if info.isHistoryWorldReadable == true {
                await loadPreviewTimeline()
            }
        } catch is CancellationError {
            // Ignore
        } catch {
            logger.error("Failed to load room preview for \(self.roomId): \(error)")
            errorReporter.report(.messageLoadFailed(error.localizedDescription))
        }

        isLoading = false
    }

    // MARK: - Private

    /// Loads a read-only timeline for the room using `getRoom` + `timelineWithConfiguration`.
    ///
    /// For public rooms with world-readable history, the SDK may allow loading
    /// the timeline even when not joined. If the room isn't available locally,
    /// this gracefully falls back to showing metadata only.
    private func loadPreviewTimeline() async {
        do {
            // Try to get the room (it may be available via the room list even if not joined).
            guard let room = try client.getRoom(roomId: roomId) else {
                logger.info("Room \(self.roomId) not locally available for timeline preview")
                return
            }

            let config = TimelineConfiguration(
                focus: .live(hideThreadedEvents: true),
                filter: .all,
                internalIdPrefix: "preview_",
                dateDividerMode: .daily,
                trackReadReceipts: .allEvents,
                reportUtds: false
            )
            let timeline = try await room.timelineWithConfiguration(configuration: config)

            // Subscribe to timeline diffs for the preview.
            let (stream, continuation) = AsyncStream<[TimelineDiff]>.makeStream()
            let listener = SDKListener<[TimelineDiff]> { diffs in
                continuation.yield(diffs)
            }

            observationTask = Task { [weak self] in
                guard let self else { return }
                self.timelineHandle = await timeline.addListener(listener: listener)

                for await diffs in stream {
                    self.applyDiffs(diffs)
                    self.rebuildMessages()
                }
            }

            // Paginate to load some initial messages.
            _ = try await timeline.paginateBackwards(numEvents: 30)
        } catch {
            logger.warning("Could not load preview timeline for \(self.roomId): \(error)")
            // Non-fatal: we still show the room metadata.
        }
    }

    private func applyDiffs(_ diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case .reset(let values):
                timelineItems = values
            case .append(let values):
                timelineItems.append(contentsOf: values)
            case .pushBack(let value):
                timelineItems.append(value)
            case .pushFront(let value):
                timelineItems.insert(value, at: 0)
            case .insert(let index, let value):
                let i = Int(index)
                if i <= timelineItems.count {
                    timelineItems.insert(value, at: i)
                }
            case .set(let index, let value):
                let i = Int(index)
                if i < timelineItems.count {
                    timelineItems[i] = value
                }
            case .remove(let index):
                let i = Int(index)
                if i < timelineItems.count {
                    timelineItems.remove(at: i)
                }
            case .clear:
                timelineItems.removeAll()
            case .popBack:
                if !timelineItems.isEmpty { timelineItems.removeLast() }
            case .popFront:
                if !timelineItems.isEmpty { timelineItems.removeFirst() }
            case .truncate(let length):
                timelineItems = Array(timelineItems.prefix(Int(length)))
            }
        }
    }

    private func rebuildMessages() {
        let mapping = messageMapper.mapItems(timelineItems)
        messages = mapping.messages
    }
}
