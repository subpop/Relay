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
import Logging

/// A swift-log `LogHandler` that forwards MatrixKit SDK records into the
/// shared ``ActivityLog``.
///
/// Install via `LoggingSystem.bootstrap` (see `RelayApp`) as part of a
/// `MultiplexLogHandler`, so the Xcode console keeps working alongside
/// the Activity Log window. The handler advertises `.trace`, so raw HTTP
/// request/response bodies flow when the SDK's level allows; the Activity
/// Log window hides trace events by default (lower the minimum-severity
/// picker to see them).
struct MatrixKitLogBridge: LogHandler {
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?

    /// The swift-log label that produced the record (e.g. `"MatrixKit.Transport"`).
    let label: String

    init(label: String) {
        self.label = label
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var merged = metadata
        if let metadata = event.metadata {
            merged.merge(metadata) { _, new in new }
        }
        if let provider = metadataProvider {
            merged.merge(provider.get()) { _, new in new }
        }
        let (category, source) = Self.route(label: label)
        let metadataStrings = merged.mapValues { "\($0)" }
        let detail = metadataStrings.isEmpty
            ? nil
            : metadataStrings
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        Task { @MainActor in
            ActivityLog.shared.log(
                category: category,
                severity: ActivityEvent.Severity(event.level),
                source: source,
                summary: event.message.description,
                detail: detail,
                metadata: metadataStrings
            )
        }
    }

    /// Maps a MatrixKit logger label onto an activity category and a
    /// display source name.
    private static func route(label: String) -> (ActivityEvent.Category, String) {
        let name = label.split(separator: ".").last.map(String.init) ?? label
        switch name {
        case "Transport":
            return (.network, name)
        case "SyncClient", "SlidingSyncClient", "SlidingSync", "SyncConnection":
            return (.sync, name)
        case "Olm", "RoomCrypto":
            return (.auth, name)
        case "MessageClient":
            // Friendly send lines ("Sent message", ...) land with the
            // per-room timeline.
            return (.timeline, name)
        case "Client":
            // Only emits the "Fetched room list" line (see
            // `MatrixClient.logRoomList`).
            return (.roomList, name)
        default:
            return (.network, name)
        }
    }
}

extension ActivityEvent.Severity {
    /// Maps a swift-log level onto an activity severity.
    init(_ level: Logger.Level) {
        switch level {
        case .trace: self = .trace
        case .debug: self = .debug
        case .info, .notice: self = .info
        case .warning: self = .warning
        case .error, .critical: self = .error
        }
    }
}
