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

import SwiftUI

/// Owns the timeline's scroll position and exposes the scroll commands.
///
/// Lives in ``TimelineView`` (created once per room) so callers outside the
/// scroll view — the compose bar, focus-on-event, and pagination-overlay
/// logic — can request scrolls without each owning a `ScrollPosition`. The
/// scroll view binds to ``position``.
///
/// Reading position captured when backward pagination is triggered.
///
/// Prepending older history above the viewport can leave the scroll offset
/// unchanged, so the viewport ends up showing the newly loaded older events
/// instead of the message the user was reading. The scroll view re-pins
/// ``PendingScrollAnchor/id`` to the viewport top once the page lands, but
/// only when the layout actually displaced it (see `anchorTarget`).
struct PendingScrollAnchor: Equatable, Sendable {
    /// The topmost visible row when pagination was triggered.
    let id: String
    /// Row count at trigger time; the landing page must grow it.
    let rowCount: Int
    /// Content height at trigger time; realized growth proves layout settled.
    let contentHeight: CGFloat
}

@MainActor
@Observable
final class TimelineScroller {
    /// The scroll position binding backing `ScrollView.scrollPosition(_:)`.
    var position = ScrollPosition(idType: String.self, edge: .bottom)

    private let scrollDuration: Double = 0.3

    // MARK: - Initial-load gating

    /// Height of the scroll viewport. Updated from `TimelineScrollView` geometry.
    private(set) var viewportHeight: CGFloat = 0
    /// Height of the scroll content. Updated from `TimelineScrollView` geometry.
    private(set) var contentHeight: CGFloat = 0
    /// Bottom inset reserved for the compose bar. Updated from `TimelineView`.
    private(set) var bottomInset: CGFloat = 0
    /// Whether the timeline is still in its initial load window. While true,
    /// `scrollToEnd` is deferred until content is scrollable.
    private(set) var isInitialLoad = true

    /// Whether the timeline content is larger than the viewport when accounting
    /// for the bottom inset.
    var isScrollable: Bool {
        guard viewportHeight > 0 else { return false }
        return contentHeight + bottomInset > viewportHeight
    }

    /// Updates scroll metrics from `TimelineScrollView` geometry.
    func updateMetrics(viewportHeight: CGFloat, contentHeight: CGFloat, bottomInset: CGFloat) {
        self.viewportHeight = viewportHeight
        self.contentHeight = contentHeight
        self.bottomInset = bottomInset
    }

    /// Marks the initial load window as complete. Called when `TimelineView`
    /// finishes `loadTimeline()`.
    func didCompleteInitialLoad() {
        // Keep isInitialLoad true until we have actually been able to scroll
        // if content is not yet scrollable; otherwise clear it.
        if isScrollable {
            isInitialLoad = false
        }
    }

    /// Scrolls to the newest message (bottom of the timeline).
    /// During the initial load, the scroll is deferred until content is
    /// scrollable (strictly initial load, accounting for `bottomInset`).
    ///
    /// The actual `ScrollPosition` mutation is always deferred to the next
    /// main-actor turn. This prevents recursive layout loops when called
    /// during a SwiftUI view-graph update (e.g. from `onChange` while new
    /// `LazyVStack` rows are being inserted).
    func scrollToEnd() {
        guard !isInitialLoad || isScrollable else { return }
        let completedInitialLoad = isInitialLoad
        Task {
            if completedInitialLoad { isInitialLoad = false }
            withAnimation(.easeOut(duration: scrollDuration)) {
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// Scrolls a specific message row to the center of the viewport.
    ///
    /// The actual `ScrollPosition` mutation is always deferred to the next
    /// main-actor turn, matching ``scrollToEnd``.
    func scrollToRow(id: String) {
        guard !isInitialLoad || isScrollable else { return }
        let completedInitialLoad = isInitialLoad
        Task {
            if completedInitialLoad { isInitialLoad = false }
            withAnimation(.easeOut(duration: scrollDuration)) {
                position.scrollTo(id: id, anchor: .center)
            }
        }
    }

    /// Re-pins a row to the viewport top after older history prepends above it.
    ///
    /// Unlike ``scrollToRow``, this is non-animated: position preservation
    /// must be invisible. Still deferred to the next main-actor turn to avoid
    /// mutating scroll state during a view update.
    func anchorRow(id: String) {
        Task { position.scrollTo(id: id, anchor: .top) }
    }

    /// Minimum realized content growth (points) that counts as a landed page.
    ///
    /// Prepended rows outside the lazy window have no height yet; anchoring
    /// before they materialize would snap against stale layout, so smaller
    /// deltas keep waiting.
    private static let anchorGrowthThreshold: CGFloat = 200

    /// Returns the row ID to pin to the viewport top, or nil when no
    /// correction is needed.
    ///
    /// Anchoring fires only when every signal agrees the prepend displaced the
    /// reading position: the fetch finished, the user is scrolled up away from
    /// the live edge, the offset never rode down with the new content (still
    /// near the top), rows actually grew, the new content materialized with
    /// real height, and the trigger-time top row is still present but no
    /// longer first.
    static func anchorTarget(
        pending: PendingScrollAnchor?,
        rowIDs: [String],
        contentHeight: CGFloat,
        isLoadingMore: Bool,
        isNearEnd: Bool,
        nearTop: Bool
    ) -> String? {
        guard let pending, !isLoadingMore else { return nil }
        guard !isNearEnd, nearTop else { return nil }
        guard rowIDs.count > pending.rowCount else { return nil }
        guard contentHeight - pending.contentHeight > anchorGrowthThreshold else {
            return nil
        }
        guard let index = rowIDs.firstIndex(of: pending.id), index > 0 else {
            return nil
        }
        return pending.id
    }

    /// Gate for backward-pagination triggers: one firing per entry into the
    /// top zone, paced by a cooldown.
    ///
    /// The scroll view evaluates this on every geometry update while the user
    /// scrolls. Firing only on *entry* (not while dwelling near the top)
    /// means a page that changes nothing can never refire on its own; the
    /// cooldown keeps deliberately chained pages measured instead of firing
    /// as fast as the network allows.
    struct BackfillGate: Equatable, Sendable {
        /// Whether the previous evaluation was inside the top zone.
        var wasNearTop = false
        /// When the last trigger fired.
        var lastFire: Date = .distantPast

        /// Minimum interval between fired triggers.
        static let cooldown: TimeInterval = 1

        /// Returns true when a trigger may fire. Call on every geometry
        /// evaluation with the current zone state; `now` is a parameter so
        /// the pacing is deterministically testable.
        mutating func shouldFire(nearTop: Bool, now: Date) -> Bool {
            defer { wasNearTop = nearTop }
            guard nearTop, !wasNearTop,
                now.timeIntervalSince(lastFire) >= Self.cooldown
            else { return false }
            lastFire = now
            return true
        }
    }
}
