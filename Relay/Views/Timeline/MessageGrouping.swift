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

// MARK: - Grouping Info

/// Precomputed layout metadata for a single message within the timeline.
/// Built once per body evaluation by ``MessageRowBuilder/buildRows(for:hasReachedStart:)``
/// so the `ForEach` body doesn't need index-based lookups.
struct MessageGroupInfo: Equatable, Sendable {
    var isFirst = false
    var showDateHeader = false
    var showGroupSpacer = false
    var isLastInGroup = true
    var showSenderName = false

    /// Whether this message's reply-to target is the immediately preceding
    /// message in the timeline. When `true`, the reply preview bubble can
    /// be omitted since the original message is already visible directly above.
    var replyIsAdjacentAbove = false

    nonisolated static func == (lhs: MessageGroupInfo, rhs: MessageGroupInfo) -> Bool {
        lhs.isFirst == rhs.isFirst
            && lhs.showDateHeader == rhs.showDateHeader
            && lhs.showGroupSpacer == rhs.showGroupSpacer
            && lhs.isLastInGroup == rhs.isLastInGroup
            && lhs.showSenderName == rhs.showSenderName
            && lhs.replyIsAdjacentAbove == rhs.replyIsAdjacentAbove
    }

    static let `default` = MessageGroupInfo()
}

/// A message bundled with its precomputed layout metadata, used as the
/// element type for the `ForEach` to avoid capturing the full groupInfo
/// dictionary or messages array in each row's closure.
struct MessageRow: Identifiable, Equatable {
    let message: TimelineMessage
    let info: MessageGroupInfo
    let isPaginationTrigger: Bool
    /// Per-message translation state baked into the row so that the
    /// table-view diff (`MessageRow == MessageRow`) catches translation
    /// changes and reloads just the affected row. Without this, a
    /// translation completing wouldn't differ in the row's payload and
    /// `NSTableView`'s `reloadData(forRowIndexes:)` short-circuit would
    /// skip the visible row.
    let translation: MessageTranslationState

    /// When non-nil, this row represents a collapsed group of consecutive
    /// system events. The ``message`` field holds the first event in the
    /// run (used for ID stability and date header computation).
    let collapsedSystemEvents: [TimelineMessage]?

    init(message: TimelineMessage, info: MessageGroupInfo, isPaginationTrigger: Bool, translation: MessageTranslationState = .idle, collapsedSystemEvents: [TimelineMessage]? = nil) {
        self.message = message
        self.info = info
        self.isPaginationTrigger = isPaginationTrigger
        self.translation = translation
        self.collapsedSystemEvents = collapsedSystemEvents
    }

    var id: String { message.id }

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.info == rhs.info
            && lhs.isPaginationTrigger == rhs.isPaginationTrigger
            && lhs.translation == rhs.translation
            && lhs.collapsedSystemEvents == rhs.collapsedSystemEvents
    }
}

// MARK: - Row Builder

/// Namespace for timeline row construction and system event collapsing.
enum MessageRowBuilder {
    /// The minimum number of consecutive system events required to collapse
    /// them into an expandable group.
    static let systemEventCollapseThreshold = 4

    /// Builds an array of ``MessageRow`` values, pairing each message with its
    /// precomputed grouping metadata. The result is passed to the table view
    /// representable so each cell receives its own lightweight `MessageRow`.
    ///
    /// Consecutive runs of system events that meet or exceed
    /// ``systemEventCollapseThreshold`` are merged into a single row with
    /// ``MessageRow/collapsedSystemEvents`` populated. Date boundaries split
    /// runs so that each collapsed group stays within a single date section.
    static func buildRows(
        for messages: [TimelineMessage],
        hasReachedStart: Bool,
        translationState: (String) -> MessageTranslationState = { _ in .idle }
    ) -> [MessageRow] {
        guard !messages.isEmpty else { return [] }
        let calendar = Calendar.current
        var result = [MessageRow]()
        result.reserveCapacity(messages.count)

        for index in messages.indices {
            let message = messages[index]
            var info = MessageGroupInfo()

            info.isFirst = index == 0

            // Date header
            if index == 0 {
                info.showDateHeader = true
            } else {
                info.showDateHeader = !calendar.isDate(
                    message.timestamp,
                    equalTo: messages[index - 1].timestamp,
                    toGranularity: .hour
                )
            }

            // Group spacer (between different sender groups, excluding system events)
            if index > 0 && !messages[index - 1].isSystemEvent && !message.isSystemEvent
                && messages[index - 1].senderID != message.senderID
                && !info.showDateHeader {
                info.showGroupSpacer = true
            }

            // Last in group
            if index < messages.count - 1 {
                let next = messages[index + 1]
                if message.isSystemEvent || next.isSystemEvent {
                    info.isLastInGroup = true
                } else {
                    let nextHasDateHeader: Bool
                    if index + 1 == 0 {
                        nextHasDateHeader = true
                    } else {
                        nextHasDateHeader = !calendar.isDate(
                            next.timestamp,
                            equalTo: message.timestamp,
                            toGranularity: .hour
                        )
                    }
                    info.isLastInGroup = next.senderID != message.senderID || nextHasDateHeader
                }
            } else {
                info.isLastInGroup = true
            }

            // Show sender name
            if !message.isOutgoing && !message.isSystemEvent {
                if index == 0 || info.showDateHeader {
                    info.showSenderName = true
                } else {
                    let prev = messages[index - 1]
                    info.showSenderName = prev.isSystemEvent || prev.senderID != message.senderID
                }
            }

            // Reply adjacency: skip the reply preview bubble when the
            // replied-to message is the one directly above.
            if let replyDetail = message.replyDetail, index > 0 {
                info.replyIsAdjacentAbove = messages[index - 1].eventID == replyDetail.eventID
            }

            result.append(MessageRow(
                message: message,
                info: info,
                isPaginationTrigger: false,
                translation: translationState(message.id)
            ))
        }

        return collapseSystemEventRuns(in: result)
    }

    /// Scans the row array for consecutive runs of system events and replaces
    /// runs that meet or exceed ``systemEventCollapseThreshold`` with a single
    /// collapsed row. Shorter runs pass through unchanged. Runs span across
    /// date boundaries so that long stretches of system events in quiet rooms
    /// collapse into a single expandable group.
    private static func collapseSystemEventRuns(in rows: [MessageRow]) -> [MessageRow] {
        var collapsed = [MessageRow]()
        collapsed.reserveCapacity(rows.count)

        var i = 0
        while i < rows.count {
            guard rows[i].message.isSystemEvent else {
                collapsed.append(rows[i])
                i += 1
                continue
            }

            // Found a system event — scan ahead for the full consecutive run,
            // ignoring date header boundaries.
            var runEnd = i + 1
            while runEnd < rows.count, rows[runEnd].message.isSystemEvent {
                runEnd += 1
            }

            let runLength = runEnd - i
            if runLength >= systemEventCollapseThreshold {
                let firstRow = rows[i]
                let events = rows[i..<runEnd].map(\.message)
                collapsed.append(MessageRow(
                    message: firstRow.message,
                    info: firstRow.info,
                    isPaginationTrigger: firstRow.isPaginationTrigger,
                    collapsedSystemEvents: events
                ))
            } else {
                collapsed.append(contentsOf: rows[i..<runEnd])
            }

            i = runEnd
        }

        return collapsed
    }
}
