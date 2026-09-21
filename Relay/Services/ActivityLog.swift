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
import OSLog
import SwiftUI

/// A ring-buffer-backed diagnostic event log for debugging sync and connection issues.
///
/// ``ActivityLog`` captures ``ActivityEvent`` entries from the client and
/// services starting at app launch. The Activity Log window reads ``events``
/// to display them; this class is the single source of truth.
///
/// The buffer is capped at ``capacity`` entries. When full, the oldest events are
/// dropped to make room for new ones. Only error events are forwarded to
/// the unified logging system, keeping the console quiet; lower-severity
/// events live in the ring buffer (and the Activity Log window) only.
@Observable
@MainActor
final class ActivityLog {
    /// The shared app-wide instance used by all services and the Activity Log window.
    static let shared = ActivityLog()

    /// The maximum number of events retained in the ring buffer.
    private let capacity: Int

    /// Per-category os.Logger instances for forwarding events to the unified logging system.
    private let loggers: [ActivityEvent.Category: Logger] = {
        var map = [ActivityEvent.Category: Logger]()
        for category in ActivityEvent.Category.allCases {
            map[category] = Logger(
                subsystem: "Relay",
                category: "ActivityLog.\(category.label.replacing(" ", with: ""))"
            )
        }
        return map
    }()

    /// The backing storage for captured events.
    private(set) var events: [ActivityEvent] = []

    /// Creates a new ``ActivityLog`` with the given capacity.
    ///
    /// - Parameter capacity: The maximum number of events to retain. Defaults to 10,000.
    init(capacity: Int = 10_000) {
        self.capacity = capacity
        events.reserveCapacity(min(capacity, 1_000))
    }

    /// Appends a new event to the log.
    ///
    /// If the buffer is at capacity, the oldest event is dropped first.
    func log(
        category: ActivityEvent.Category,
        severity: ActivityEvent.Severity,
        source: String,
        summary: String,
        detail: String? = nil,
        roomId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let event = ActivityEvent(
            category: category,
            severity: severity,
            source: source,
            summary: summary,
            detail: detail,
            roomId: roomId,
            metadata: metadata
        )
        if events.count >= capacity {
            events.removeFirst()
        }
        events.append(event)

        if event.severity >= .error, let logger = loggers[category] {
            forward(event, to: logger)
        }
    }

    /// Forwards an event to the unified logging system at the appropriate log level.
    private nonisolated func forward(_ event: ActivityEvent, to logger: Logger) {
        let detail = event.detail ?? ""
        let roomId = event.roomId ?? ""

        switch event.severity {
        case .trace:
            logger.trace("[\(event.source, privacy: .public)] \(event.summary, privacy: .public) \(detail, privacy: .private(mask: .hash)) \(roomId, privacy: .private(mask: .hash))")
        case .debug:
            logger.debug("[\(event.source, privacy: .public)] \(event.summary, privacy: .public) \(detail, privacy: .private(mask: .hash)) \(roomId, privacy: .private(mask: .hash))")
        case .info:
            logger.info("[\(event.source, privacy: .public)] \(event.summary, privacy: .public) \(detail, privacy: .private(mask: .hash)) \(roomId, privacy: .private(mask: .hash))")
        case .warning:
            logger.warning("[\(event.source, privacy: .public)] \(event.summary, privacy: .public) \(detail, privacy: .private(mask: .hash)) \(roomId, privacy: .private(mask: .hash))")
        case .error:
            logger.error("[\(event.source, privacy: .public)] \(event.summary, privacy: .public) \(detail, privacy: .private(mask: .hash)) \(roomId, privacy: .private(mask: .hash))")
        }
    }

    /// Removes all captured events.
    func clear() {
        events.removeAll()
    }
}

// MARK: - Environment Key

private struct ActivityLogKey: EnvironmentKey {
    static let defaultValue = ActivityLog.shared
}

extension EnvironmentValues {
    /// The activity log used for diagnostic event capture and display.
    var activityLog: ActivityLog {
        get { self[ActivityLogKey.self] }
        set { self[ActivityLogKey.self] = newValue }
    }
}
