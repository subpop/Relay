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

/// Shared configuration values that both timeline renderers
/// (``TimelineTableViewRepresentable`` and ``TimelineLazyVStackView``) need.
///
/// Grouping these into a struct makes the renderer contract explicit,
/// eliminates parameter duplication in ``TimelineView/timelineRenderer``,
/// and ensures both renderers receive the same data.
struct TimelineRendererConfig: Equatable {
    /// The pre-built message rows to display.
    let rows: [MessageRow]
    /// Whether the unread marker should be shown.
    let showUnreadMarker: Bool
    /// The ID of the first unread message (for the "New" divider).
    let firstUnreadMessageId: String?
    /// The event ID of the currently highlighted message (reply navigation).
    let highlightedMessageId: String?
    /// Whether link preview cards should be rendered.
    let showURLPreviews: Bool
    /// Whether forward pagination has reached the live edge.
    let hasReachedEnd: Bool
    /// Whether the timeline is showing live messages.
    let isLive: Bool
    /// Whether the typing indicator overlay is currently visible.
    let typingIndicatorShown: Bool
}

/// Shared callbacks that both timeline renderers invoke to communicate
/// scroll state and pagination requests back to ``TimelineView``.
struct TimelineRendererCallbacks {
    /// Called when the near-bottom state changes (drives auto-scroll and read receipts).
    var onNearBottomChanged: (Bool) -> Void = { _ in }
    /// Called when the user scrolls near the top and more history should be loaded.
    var onPaginateBackward: () -> Void = {}
    /// Called when the user scrolls near the bottom of an event-focused timeline.
    var onPaginateForward: () -> Void = {}
}
