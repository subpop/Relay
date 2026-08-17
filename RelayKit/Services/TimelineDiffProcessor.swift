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

/// Applies timeline diff operations from the Matrix Rust SDK to an in-memory
/// array of ``TimelineItem`` values, tracking which indices changed so the
/// mapper can perform incremental rebuilds.
///
/// ``TimelineDiffProcessor`` owns the raw ``timelineItems`` array, a parallel
/// ``timelineItemIDs`` array for O(1) cache lookups without FFI calls, and
/// the ``pendingChangedIndices`` set that tells the rebuilder which items
/// need re-mapping.
struct TimelineDiffProcessor {

    /// The current array of raw SDK timeline items.
    private(set) var timelineItems: [TimelineItem] = []

    /// Pre-extracted event/transaction IDs for each item in ``timelineItems``,
    /// maintained in parallel during ``applyDiffs``. Used to avoid FFI calls
    /// during incremental cache lookups in the mapper. `nil` entries
    /// represent non-event items (e.g. date dividers) that have no ID.
    private(set) var timelineItemIDs: [String?] = []

    /// Tracks which indices in ``timelineItems`` were modified by the latest
    /// batch of diffs. `nil` means a full remap is required (e.g. after a
    /// reset or clear). An empty set means nothing changed.
    private(set) var pendingChangedIndices: IndexSet? = IndexSet()

    /// Resets the pending changed indices to an empty set, indicating that
    /// the current changes have been consumed by a rebuild pass.
    mutating func resetPendingChangedIndices() {
        pendingChangedIndices = IndexSet()
    }

    /// Clears all items and resets tracking state.
    mutating func clear() {
        timelineItems = []
        timelineItemIDs = []
        pendingChangedIndices = IndexSet()
    }

    // MARK: - Diff Application

    /// Applies a batch of timeline diffs to the internal arrays and tracks
    /// which indices were modified.
    ///
    /// - Parameters:
    ///   - diffs: The diff batch from the SDK.
    ///   - roomLabel: A human-readable room label for activity log entries.
    ///   - roomId: The room ID for activity log entries.
    ///   - activityLog: Optional activity log for recording diff summaries.
    // swiftlint:disable:next cyclomatic_complexity
    mutating func applyDiffs(
        _ diffs: [TimelineDiff],
        roomLabel: String,
        roomId: String,
        activityLog: ActivityLog?
    ) {
        let itemCountBefore = timelineItems.count
        let state = PerformanceSignposts.timeline.beginInterval(
            PerformanceSignposts.TimelineName.applyDiffs,
            "\(diffs.count) diffs, \(itemCountBefore) items"
        )
        for diff in diffs {
            switch diff {
            case .reset(let values):
                let oldIDs = timelineItemIDs
                let newIDs = values.map(Self.extractItemID)
                timelineItemIDs = newIDs
                timelineItems = values

                if oldIDs.isEmpty {
                    // First load — full remap required.
                    pendingChangedIndices = nil
                } else {
                    // Diff old vs new IDs to avoid a full remap when most
                    // items are unchanged (e.g. room resume with a few
                    // new messages appended).
                    markChangedIndicesForReset(oldIDs: oldIDs, newIDs: newIDs)
                }

            case .append(let values):
                let start = timelineItems.count
                timelineItemIDs.append(contentsOf: values.map(Self.extractItemID))
                timelineItems.append(contentsOf: values)
                markIndicesChanged(start ..< timelineItems.count)

            case .pushBack(let value):
                let idx = timelineItems.count
                timelineItemIDs.append(Self.extractItemID(value))
                timelineItems.append(value)
                markIndexChanged(idx)

            case .pushFront(let value):
                // Inserting at 0 shifts every existing index up by 1.
                shiftPendingIndices(by: 1, from: 0)
                timelineItemIDs.insert(Self.extractItemID(value), at: 0)
                timelineItems.insert(value, at: 0)
                markIndexChanged(0)

            // swiftlint:disable identifier_name
            case .insert(let index, let value):
                let i = Int(index)
                if i <= timelineItems.count {
                    shiftPendingIndices(by: 1, from: i)
                    timelineItemIDs.insert(Self.extractItemID(value), at: i)
                    timelineItems.insert(value, at: i)
                    markIndexChanged(i)
                }

            case .set(let index, let value):
                let i = Int(index)
                if i < timelineItems.count {
                    timelineItemIDs[i] = Self.extractItemID(value)
                    timelineItems[i] = value
                    markIndexChanged(i)
                }

            case .remove(let index):
                let i = Int(index)
                if i < timelineItems.count {
                    timelineItemIDs.remove(at: i)
                    timelineItems.remove(at: i)
                    // Remove this index and shift everything above it down.
                    pendingChangedIndices?.remove(i)
                    shiftPendingIndices(by: -1, from: i + 1)
                    // Mark the new occupant of this index as changed, since
                    // it may now pair with a different neighbor for grouping.
                    if i < timelineItems.count {
                        markIndexChanged(i)
                    }
                }
            // swiftlint:enable identifier_name

            case .clear:
                timelineItemIDs.removeAll()
                timelineItems.removeAll()
                pendingChangedIndices = nil

            case .popBack:
                if !timelineItems.isEmpty {
                    timelineItemIDs.removeLast()
                    timelineItems.removeLast()
                    // No index to mark — the item is gone. Cache will be
                    // pruned naturally when it's absent from the next rebuild.
                }

            case .popFront:
                if !timelineItems.isEmpty {
                    timelineItemIDs.removeFirst()
                    timelineItems.removeFirst()
                    pendingChangedIndices?.remove(0)
                    shiftPendingIndices(by: -1, from: 1)
                    if !timelineItems.isEmpty {
                        markIndexChanged(0)
                    }
                }

            case .truncate(let length):
                let len = Int(length)
                timelineItemIDs = Array(timelineItemIDs.prefix(len))
                timelineItems = Array(timelineItems.prefix(len))
                // Discard any tracked indices beyond the new length.
                if var indices = pendingChangedIndices {
                    indices = indices.filteredIndexSet { $0 < len }
                    pendingChangedIndices = indices
                }
            }
        }
        let itemCountAfter = timelineItems.count
        PerformanceSignposts.timeline.endInterval(
            PerformanceSignposts.TimelineName.applyDiffs,
            state,
            "\(itemCountAfter) items after"
        )

        let diffSummary = diffs.map { diff -> String in
            switch diff {
            case .reset(let v): "reset(\(v.count))"
            case .append(let v): "append(\(v.count))"
            case .pushBack: "pushBack"
            case .pushFront: "pushFront"
            case .insert(let idx, _): "insert(@\(idx))"
            case .set(let idx, _): "set(@\(idx))"
            case .remove(let idx): "remove(@\(idx))"
            case .clear: "clear"
            case .popBack: "popBack"
            case .popFront: "popFront"
            case .truncate(let len): "truncate(\(len))"
            }
        }.joined(separator: ", ")
        let changedDesc = pendingChangedIndices.map { "\($0.count) changed" } ?? "full remap"
        activityLog?.log(
            category: .timeline, severity: .debug, source: "TimelineDiffProcessor",
            summary: "\(diffs.count) diff(s) in \(roomLabel): \(itemCountBefore) → \(itemCountAfter) items",
            detail: "Diffs: \(diffSummary)\nIndices: \(changedDesc)",
            roomId: roomId
        )
    }

    // MARK: - Item ID Extraction

    /// Extracts the stable unique ID from a timeline item. Uses the SDK's
    /// `uniqueId()` which remains constant across the local echo → server
    /// confirmation transition.
    static func extractItemID(_ item: TimelineItem) -> String? {
        guard item.asEvent() != nil else { return nil }
        return item.uniqueId().id
    }

    // MARK: - Index Tracking Helpers

    /// Records a single index as changed, initializing the set if needed.
    private mutating func markIndexChanged(_ index: Int) {
        if pendingChangedIndices == nil {
            // nil means "full remap" — no point tracking individual indices.
            return
        }
        pendingChangedIndices?.insert(index)
    }

    /// Records a range of indices as changed.
    private mutating func markIndicesChanged(_ range: Range<Int>) {
        if pendingChangedIndices == nil { return }
        pendingChangedIndices?.insert(integersIn: range)
    }

    /// Shifts all tracked indices >= `from` by `delta` (positive = right, negative = left).
    private mutating func shiftPendingIndices(by delta: Int, from start: Int) {
        guard var indices = pendingChangedIndices else { return }
        let affected = indices.filteredIndexSet { $0 >= start }
        indices.subtract(affected)
        for idx in affected {
            let shifted = idx + delta
            if shifted >= 0 {
                indices.insert(shifted)
            }
        }
        pendingChangedIndices = indices
    }

    /// Compares old and new item IDs after a `.reset` diff and marks only the
    /// indices that actually changed, avoiding a full remap when most content
    /// is unchanged (e.g. resuming a room with a few new messages).
    ///
    /// Falls back to a full remap (`pendingChangedIndices = nil`) when the
    /// arrays have diverged too much to cheaply diff (shared prefix < 50%
    /// of the smaller array).
    private mutating func markChangedIndicesForReset(
        oldIDs: [String?],
        newIDs: [String?]
    ) {
        // Find the longest shared prefix of identical IDs.
        let minCount = min(oldIDs.count, newIDs.count)
        var sharedPrefix = 0
        while sharedPrefix < minCount && oldIDs[sharedPrefix] == newIDs[sharedPrefix] {
            sharedPrefix += 1
        }

        // If less than half the items match, a full remap is cheaper than
        // tracking a large changed set.
        if sharedPrefix < minCount / 2 {
            pendingChangedIndices = nil
            return
        }

        // Mark every index beyond the shared prefix as changed.
        if sharedPrefix < newIDs.count {
            if pendingChangedIndices == nil {
                pendingChangedIndices = IndexSet()
            }
            pendingChangedIndices?.insert(integersIn: sharedPrefix..<newIDs.count)
        }
    }

    /// Counts the number of message-like (non-state) event items currently
    /// in ``timelineItems``.
    func countMsgLikeItems() -> Int {
        timelineItems.lazy
            .compactMap { $0.asEvent() }
            .filter {
                if case .msgLike = $0.content { return true }
                return false
            }
            .count
    }
}
