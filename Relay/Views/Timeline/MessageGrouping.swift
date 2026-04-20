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
/// Built once per body evaluation by ``TimelineView/buildRows(for:hasReachedStart:)``
/// so the `ForEach` body doesn't need index-based lookups.
struct MessageGroupInfo: Equatable, Sendable {
    var isFirst = false
    var showDateHeader = false
    var showGroupSpacer = false
    var isLastInGroup = true
    var showSenderName = false

    nonisolated static func == (lhs: MessageGroupInfo, rhs: MessageGroupInfo) -> Bool {
        lhs.isFirst == rhs.isFirst
            && lhs.showDateHeader == rhs.showDateHeader
            && lhs.showGroupSpacer == rhs.showGroupSpacer
            && lhs.isLastInGroup == rhs.isLastInGroup
            && lhs.showSenderName == rhs.showSenderName
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

    var id: String { message.id }

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.info == rhs.info
            && lhs.isPaginationTrigger == rhs.isPaginationTrigger
    }
}

// MARK: - Row Builder

extension TimelineView {
    /// Builds an array of ``MessageRow`` values, pairing each message with its
    /// precomputed grouping metadata. The result is passed to the table view
    /// representable so each cell receives its own lightweight `MessageRow`.
    static func buildRows(
        for messages: [TimelineMessage],
        hasReachedStart: Bool
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

            result.append(MessageRow(
                message: message,
                info: info,
                isPaginationTrigger: false
            ))
        }
        return result
    }
}
