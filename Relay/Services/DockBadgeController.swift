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

import AppKit
import MatrixKit
import Observation

/// Keeps the dock tile badge in sync with room unread state.
///
/// The badge is derived from ``RelayClient/rooms``,
/// ``RelayClient/notificationModeCache``, and per-room unread/highlight
/// counts, all of which mutate on nearly every sync tick. Reading them
/// from the `App` struct's body would re-evaluate the scene list (and
/// rebuild the menu bar) on every tick, which drops inactive Window menu
/// items on macOS 26. This controller observes the same state from a
/// detached task instead, so sync activity never invalidates the app or
/// scene bodies.
@MainActor
final class DockBadgeController {
    /// The per-room inputs to the badge count, snapshotted from the client.
    struct RoomBadgeState: Sendable {
        var mode: RoomNotificationMode?
        var unread: Int
        var highlight: Int
        var isDirect: Bool
    }

    /// The total badge count for the given rooms.
    ///
    /// - All Messages: counts all unread messages
    /// - Mentions & Keywords Only: counts only unread mentions
    /// - Mute: counts nothing
    /// - Default (uncached): DMs count all notifications, groups count highlights only
    static func badgeCount(for rooms: [RoomBadgeState]) -> Int {
        rooms.reduce(0) { total, room in
            switch room.mode {
            case .mute:
                return total
            case .mentionsAndKeywordsOnly:
                return total + room.highlight
            case .allMessages:
                return total + room.unread
            case nil:
                return total + (room.isDirect ? room.unread : room.highlight)
            }
        }
    }

    private let client: RelayClient

    init(client: RelayClient) {
        self.client = client
    }

    /// Recomputes the badge whenever observed room state changes. Runs
    /// until the surrounding task is cancelled.
    func run() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        await withTaskCancellationHandler {
            withObservationTracking {
                Self.apply(Self.badgeCount(for: self.snapshot()))
            } onChange: {
                continuation.yield()
            }
            for await _ in stream {
                // Coalesce sync bursts before recomputing.
                try? await Task.sleep(for: .milliseconds(250))
                withObservationTracking {
                    Self.apply(Self.badgeCount(for: self.snapshot()))
                } onChange: {
                    continuation.yield()
                }
            }
        } onCancel: {
            continuation.finish()
        }
    }

    private func snapshot() -> [RoomBadgeState] {
        client.rooms.map { room in
            RoomBadgeState(
                mode: client.notificationModeCache[room.roomId.value],
                unread: client.displayUnreadCount(for: room),
                highlight: client.displayHighlightCount(for: room),
                isDirect: room.isDirect
            )
        }
    }

    private static func apply(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
