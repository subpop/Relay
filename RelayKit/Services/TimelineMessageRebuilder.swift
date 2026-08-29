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
import RelayInterface
import os

/// Orchestrates incremental mapping of raw SDK timeline items into
/// ``TimelineMessage`` models.
///
/// ``TimelineMessageRebuilder`` captures a snapshot of timeline items and
/// changed indices, dispatches the mapping to a background thread via
/// ``TimelineMessageMapper``, and applies the result back on the main actor.
/// It manages the message cache, generation counter for staleness detection,
/// unread marker computation, and reply resolution.
final class TimelineMessageRebuilder {

    /// Previously mapped messages keyed by event/transaction ID for O(1) reuse
    /// during incremental rebuilds.
    private var messageCache: [String: TimelineMessage] = [:]

    /// Monotonically increasing counter used to discard stale results from
    /// background mapping tasks that were superseded by a newer rebuild.
    private var rebuildGeneration: UInt = 0

    /// Event IDs for which reply details have already been fetched from the
    /// server, preventing redundant fetch requests.
    private var fetchedReplyEventIds: Set<String> = []

    private var hasComputedUnreadMarker = false
    private let unreadCount: Int
    private let roomLabel: String
    private let roomId: String
    private weak var activityLog: ActivityLog?

    /// Debounce task for row rebuilds. Collapses rapid successive
    /// `applyMappingResult()` calls into a single row swap so the
    /// `LazyVStack` only re-layouts once per batch.
    private var rowRebuildTask: Task<Void, Never>?

    /// Called when the messages array has been updated.
    var onMessagesUpdated: ((_ messages: [TimelineMessage], _ version: UInt) -> Void)?

    /// Called when the message rows have been rebuilt.
    var onMessageRowsUpdated: ((_ rows: [MessageRow], _ version: UInt) -> Void)?

    /// Called when the unread marker position is first computed.
    var onUnreadMarkerComputed: ((String) -> Void)?

    /// Called to fetch reply details for unresolved events.
    var fetchReplyDetails: ((String) async throws -> Void)?

    /// A monotonically increasing version counter, bumped each time the
    /// messages array is updated with changed content.
    private(set) var messagesVersion: UInt = 0

    /// The most recently produced messages array.
    private(set) var messages: [TimelineMessage] = []

    /// Pre-computed message rows with grouping metadata, ready for rendering.
    private(set) var messageRows: [MessageRow] = []

    /// Version counter for messageRows, bumped each time rows are rebuilt.
    private(set) var messageRowsVersion: UInt = 0

    /// Whether to show membership events (joins, leaves, etc.) in the timeline.
    var showMembershipEvents = true

    /// Whether to show state events (room name, topic, etc.) in the timeline.
    var showStateEvents = true

    /// Whether backward pagination has reached the beginning of the room's history.
    /// Passed through to `MessageRowBuilder.buildRows` for pagination trigger computation.
    var hasReachedStart = false

    init(unreadCount: Int, roomLabel: String, roomId: String, activityLog: ActivityLog?) {
        self.unreadCount = unreadCount
        self.roomLabel = roomLabel
        self.roomId = roomId
        self.activityLog = activityLog
    }

    /// Invalidates the generation counter so any in-flight background mapping
    /// task is discarded. Call this when the timeline is torn down or suspended.
    func invalidateGeneration() {
        rebuildGeneration &+= 1
    }

    /// Resets all internal state (cache, generation, fetched replies, unread marker).
    func reset() {
        messageCache = [:]
        rebuildGeneration &+= 1
        fetchedReplyEventIds = []
        hasComputedUnreadMarker = false
        messages = []
        messagesVersion = 0
        messageRows = []
        messageRowsVersion = 0
        rowRebuildTask?.cancel()
        rowRebuildTask = nil
    }

    /// Updates the event-filtering preferences and rebuilds message rows
    /// from the current messages. Called when the user toggles membership
    /// or state event visibility in room settings.
    func updateFilterPreferences(showMembership: Bool, showState: Bool) {
        guard showMembership != showMembershipEvents || showState != showStateEvents else { return }
        showMembershipEvents = showMembership
        showStateEvents = showState
        rebuildMessageRows()
    }

    /// Performs an incremental rebuild of messages, mapping only changed items
    /// on a background thread and reusing cached messages for unchanged items.
    ///
    /// - Parameters:
    ///   - items: The current raw SDK timeline items.
    ///   - itemIDs: Pre-extracted item IDs, parallel to `items`.
    ///   - changedIndices: Which indices need re-mapping. `nil` means full remap.
    ///   - mapper: The stateless mapper to use for transformation.
    ///   - pendingIndicesResetter: Called to reset the diff processor's pending indices.
    func rebuild(
        items: [TimelineItem],
        itemIDs: [String?],
        changedIndices: IndexSet?,
        mapper: TimelineMessageMapper,
        pendingIndicesResetter: () -> Void
    ) async {
        let itemCount = items.count
        let changedCount = changedIndices?.count ?? -1
        let rebuildState = PerformanceSignposts.timeline.beginInterval(
            PerformanceSignposts.TimelineName.rebuildMessages,
            "\(itemCount) items, changed: \(changedCount)"
        )

        // Capture current cache for the background pass.
        let cache = messageCache

        // Bump the generation so we can discard stale results.
        rebuildGeneration &+= 1
        let generation = rebuildGeneration

        // Reset the pending set so subsequent diffs accumulate into a fresh set.
        pendingIndicesResetter()

        let mapping = await mapper.mapItemsIncrementally(
            items,
            itemIDs: itemIDs,
            changedIndices: changedIndices,
            existingMessages: cache
        )

        // Discard the result if a newer rebuild was started while we
        // were mapping on the background thread.
        guard generation == rebuildGeneration else {
            PerformanceSignposts.timeline.endInterval(
                PerformanceSignposts.TimelineName.rebuildMessages,
                rebuildState,
                "discarded (stale generation)"
            )
            activityLog?.log(
                category: .timeline, severity: .debug, source: "TimelineMessageRebuilder",
                summary: "Rebuild discarded in \(roomLabel) (stale generation \(generation))",
                roomId: roomId
            )
            return
        }

        // Apply the result.
        applyMappingResult(mapping)
        PerformanceSignposts.timeline.endInterval(
            PerformanceSignposts.TimelineName.rebuildMessages,
            rebuildState,
            "\(mapping.messages.count) messages"
        )
    }

    // MARK: - Private

    /// Applies a mapping result to the published state.
    private func applyMappingResult(_ mapping: TimelineMessageMapper.MappingResult) {
        let applyState = PerformanceSignposts.timeline.beginInterval(
            PerformanceSignposts.TimelineName.applyMappingResult,
            "\(mapping.messages.count) messages"
        )

        // Update the cache with the freshly mapped messages.
        var newCache: [String: TimelineMessage] = [:]
        newCache.reserveCapacity(mapping.messages.count)
        for message in mapping.messages {
            newCache[message.id] = message
        }
        messageCache = newCache

        // Suppress the notification when the mapped messages haven't actually
        // changed. Without this guard, every diff batch replaces the array
        // reference, causing a full SwiftUI body re-evaluation.
        let currentCount = messages.count
        let eqState = PerformanceSignposts.timeline.beginInterval(
            PerformanceSignposts.TimelineName.equalityCheck,
            "\(mapping.messages.count) vs \(currentCount)"
        )
        let changed = mapping.messages != messages
        PerformanceSignposts.timeline.endInterval(
            PerformanceSignposts.TimelineName.equalityCheck,
            eqState,
            "changed: \(changed)"
        )

        if changed {
            messages = mapping.messages
            messagesVersion &+= 1
            activityLog?.log(
                category: .timeline, severity: .debug, source: "TimelineMessageRebuilder",
                summary: "Messages updated in \(roomLabel): \(mapping.messages.count) messages (v\(messagesVersion))",
                roomId: roomId
            )
            onMessagesUpdated?(messages, messagesVersion)

            // Rebuild message rows from the filtered messages.
            rebuildMessageRows()
        }

        computeUnreadMarkerIfNeeded(mapping.messages)
        resolveUnfetchedReplies(mapping.unresolvedReplyEventIds)

        PerformanceSignposts.timeline.endInterval(
            PerformanceSignposts.TimelineName.applyMappingResult,
            applyState
        )
    }

    /// Rebuilds message rows from the current messages with filtering applied.
    /// Debounced: rapid successive calls collapse into a single emission so the
    /// `LazyVStack` only re-layouts once per batch.
    private func rebuildMessageRows() {
        rowRebuildTask?.cancel()
        rowRebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Use a longer debounce during initial load (few messages, many
            // rapid diffs from the SDK) and a shorter one for incremental
            // updates once the timeline is populated.
            let delay: Duration = messages.count < 20 ? .milliseconds(300) : .milliseconds(50)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let filtered = messages.filter { message in
                switch message.kind {
                case .membership, .profileChange:
                    return showMembershipEvents
                case .stateEvent:
                    return showStateEvents
                default:
                    return true
                }
            }
            let newRows = MessageRowBuilder.buildRows(for: filtered, hasReachedStart: hasReachedStart)
            guard newRows != messageRows else { return }
            messageRows = newRows
            messageRowsVersion &+= 1
            onMessageRowsUpdated?(messageRows, messageRowsVersion)
        }
    }

    private func computeUnreadMarkerIfNeeded(_ result: [TimelineMessage]) {
        guard !hasComputedUnreadMarker, unreadCount > 0, !result.isEmpty else { return }
        hasComputedUnreadMarker = true
        let incomingMessages = result.filter { !$0.isOutgoing }
        if unreadCount <= incomingMessages.count {
            let markerIndex = incomingMessages.count - unreadCount
            onUnreadMarkerComputed?(incomingMessages[markerIndex].id)
        }
    }

    private func resolveUnfetchedReplies(_ pendingIds: Set<String>) {
        let newFetchIds = pendingIds.subtracting(fetchedReplyEventIds)
        guard !newFetchIds.isEmpty, let fetchReplyDetails else { return }
        fetchedReplyEventIds.formUnion(newFetchIds)
        Task {
            for eventId in newFetchIds {
                try? await fetchReplyDetails(eventId)
            }
        }
    }
}
