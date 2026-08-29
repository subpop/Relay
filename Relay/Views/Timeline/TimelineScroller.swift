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
@MainActor
@Observable
final class TimelineScroller {
    /// The scroll position binding backing `ScrollView.scrollPosition(_:)`.
    var position = ScrollPosition(idType: String.self, edge: .bottom)

    /// Suppresses the scroll animation on the first scroll after the view
    /// appears (e.g. room switch), so the timeline lands at its initial
    /// position immediately rather than animating there.
    private var suppressAnimation = true

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
    /// Clamps out the animation on the very first scroll after appearance.
    /// During the initial load, the scroll is deferred until content is
    /// scrollable (strictly initial load, accounting for `bottomInset`).
    func scrollToEnd(animated: Bool = true) {
        if isInitialLoad && !isScrollable {
            return
        }
        let animate = animated && !suppressAnimation
        // Only clear suppression after a real scroll could happen.
        suppressAnimation = false
        if isInitialLoad {
            isInitialLoad = false
        }
        if animate {
            withAnimation(.easeOut(duration: scrollDuration)) {
                position.scrollTo(edge: .bottom)
            }
        } else {
            position.scrollTo(edge: .bottom)
        }
    }

    /// Scrolls a specific message row to the center of the viewport.
    func scrollToRow(id: String, animated: Bool = true, force: Bool = false) {
        if isInitialLoad && !isScrollable && !force {
            return
        }
        if isInitialLoad && isScrollable {
            isInitialLoad = false
        }
        if animated {
            withAnimation(.easeOut(duration: scrollDuration)) {
                position.scrollTo(id: id, anchor: .center)
            }
        } else {
            position.scrollTo(id: id, anchor: .center)
        }
    }
}
