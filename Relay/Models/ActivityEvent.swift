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

/// A single diagnostic event captured from the service layer for debugging.
///
/// ``ActivityEvent`` provides an "under the hood" view into the sync pipeline, room
/// list management, timeline diff processing, and network state. Events are stored
/// in a ring buffer by ``ActivityLogProtocol`` and displayed in the Activity Log window.
struct ActivityEvent: Identifiable, Sendable, Codable {
    /// The subsystem that produced the event.
    enum Category: String, Sendable, CaseIterable, Identifiable, Codable {
        case sync
        case roomList
        case timeline
        case network
        case auth
        case media
        case call

        var id: String { rawValue }

        /// A human-readable label for display in the UI.
        nonisolated var label: String {
            switch self {
            case .sync: "Sync"
            case .roomList: "Room List"
            case .timeline: "Timeline"
            case .network: "Network"
            case .auth: "Auth"
            case .media: "Media"
            case .call: "Call"
            }
        }

        /// An SF Symbol icon name for this category.
        nonisolated var icon: String {
            switch self {
            case .sync: "arrow.triangle.2.circlepath"
            case .roomList: "list.bullet"
            case .timeline: "text.bubble"
            case .network: "network"
            case .auth: "person.badge.key"
            case .media: "photo"
            case .call: "phone.fill"
            }
        }
    }

    /// The severity level of the event.
    enum Severity: String, Sendable, CaseIterable, Identifiable, Comparable, Codable {
        case trace
        case debug
        case info
        case warning
        case error

        var id: String { rawValue }

        /// A human-readable label for display in the UI.
        nonisolated var label: String {
            switch self {
            case .trace: "Trace"
            case .debug: "Debug"
            case .info: "Info"
            case .warning: "Warning"
            case .error: "Error"
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            let order: [Severity] = [.trace, .debug, .info, .warning, .error]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    /// A stable, unique identifier for this event.
    let id: UUID

    /// The time at which the event was captured.
    let timestamp: Date

    /// The subsystem that produced the event.
    let category: Category

    /// The severity level of the event.
    let severity: Severity

    /// The specific component that produced the event (e.g. ``"SyncManager"``, ``"RoomListManager"``).
    let source: String

    /// A one-line summary of what happened.
    let summary: String

    /// An optional multi-line description with additional context.
    let detail: String?

    /// The Matrix room ID this event relates to, if applicable.
    let roomId: String?

    /// Arbitrary key-value metadata for filtering and search.
    let metadata: [String: String]

    /// Creates a new ``ActivityEvent``.
    nonisolated init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        category: Category,
        severity: Severity,
        source: String,
        summary: String,
        detail: String? = nil,
        roomId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.source = source
        self.summary = summary
        self.detail = detail
        self.roomId = roomId
        self.metadata = metadata
    }

    /// The timestamp formatted with millisecond precision (e.g. ``"14:30:05.123"``).
    nonisolated var formattedTimestamp: String {
        timestamp.formatted(
            .dateTime
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
                .secondFraction(.fractional(3))
        )
    }
}
