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

import RelayInterface
import SwiftUI

/// Pure SwiftUI timeline renderer using `ScrollView` + `LazyVStack`.
///
/// Displays message rows in natural order (oldest first) with:
/// - Bottom-anchored initial scroll position
/// - Backward/forward pagination via scroll geometry
/// - Read receipt advancement via visibility tracking
/// - Scroll-to-bottom button when scrolled away from live
struct TimelineScrollView: View {
    let rows: [MessageRow]
    let config: TimelineConfig
    let bottomInset: CGFloat
    /// The consolidated timeline interaction callbacks. Injected into the
    /// environment so row views can dispatch actions.
    let actions: TimelineActions
    @Binding var typingUsers: [TypingUser]
    /// Shared scroll-state owner. Binds the underlying `ScrollPosition` and
    /// receives scroll commands (`scrollToEnd` / `scrollToRow`) from callers.
    @Bindable var scroller: TimelineScroller
    let onNearEndChanged: (Bool) -> Void
    let onPaginateBackward: () -> Void
    let onPaginateForward: () -> Void
    /// The ID of the bottom-most (newest) message currently visible, or `nil`.
    /// Reported whenever the visible set changes.
    let onBottomMostVisibleMessageChanged: (String?) -> Void
    let onScrollSettled: () -> Void

    @State private var isUserScrolling = false
    @State private var isNearEndLatched = true
    @State private var visibleRowIDs: Set<String> = []
    @State private var swipeState = TimelineSwipeState()
    @State private var swipeHandler = SwipeScrollHandler()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(rows) { row in
                    TimelineRowView(
                        row: row,
                        isHighlighted: config.highlightedMessageID == row.message.eventID,
                        isUnreadDivider: config.showUnreadMarker && row.message.id == config.firstUnreadMessageID,
                        showURLPreviews: config.showURLPreviews,
                        onAppear: { _ in },
                        swipeOffset: swipeState.swipingMessageId == row.id ? swipeState.offset : 0,
                        swipeIsLocked: swipeState.swipingMessageId == row.id && swipeState.isLocked
                    )
                    .id(row.id)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: swipeHandler.hoveredRowID = row.id
                        case .ended: if swipeHandler.hoveredRowID == row.id { swipeHandler.hoveredRowID = nil }
                        }
                    }
                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                        // Ensure scroll state mutation callbacks are deferred until the
                        // next main actor pass.
                        Task { @MainActor in
                            if visible {
                                visibleRowIDs.insert(row.id)
                            } else {
                                visibleRowIDs.remove(row.id)
                            }
                        }
                    }
                }
                TypingIndicatorRowView(users: typingUsers)
                    .frame(height: typingUsers.isEmpty ? 0 : nil)
                    .opacity(typingUsers.isEmpty ? 0 : 1)
                    .allowsHitTesting(!typingUsers.isEmpty)
                    .animation(.easeInOut, value: typingUsers.isEmpty)
            }
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scroller.position)
        .environment(\.timelineActions, actions)
        .onTapGesture {
            if swipeState.isLocked {
                TimelineSwipeController.dismissActionBar(swipeState)
            }
        }
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            let viewportHeight = geometry.containerSize.height
            let viewportBottom = geometry.contentOffset.y + viewportHeight
            let distanceFromBottom = max(0, geometry.contentSize.height - viewportBottom)

            // Consider the end of the timeline reached when we're within 7.5%
            // of the viewport height.
            let nearEndThreshold = max(75, viewportHeight * 0.075)

            // Start fetching newer messages when there's still about a third of
            // the content left to scroll through.
            let nearBottomThreshold = max(200, viewportHeight * 0.3)

            // Load older messages at 40% of the viewport height. Load them
            // early to minimize jumping around in the timeline.
            let nearTopThreshold = max(300, viewportHeight * 0.4)

            return ScrollMetrics(
                containerSizeHeight: viewportHeight,
                contentHeight: geometry.contentSize.height,
                nearBottom: distanceFromBottom < nearBottomThreshold,
                nearTop: geometry.contentOffset.y < nearTopThreshold,
                nearEnd: distanceFromBottom < nearEndThreshold
            )
        } action: { _, new in
            // Ensure scroll state mutation callbacks are deferred until the
            // next main actor pass.
            Task { @MainActor in
                scroller.updateMetrics(
                    viewportHeight: new.containerSizeHeight,
                    contentHeight: new.contentHeight,
                    bottomInset: bottomInset
                )
                guard rows.count > 0 else { return }
                if new.nearEnd {
                    if !isNearEndLatched {
                        isNearEndLatched = true
                        onNearEndChanged(true)
                    }
                } else if isUserScrolling {
                    if isNearEndLatched {
                        isNearEndLatched = false
                        onNearEndChanged(false)
                    }
                }

                if new.nearTop, !rows.isEmpty, !config.isLoadingMore, isUserScrolling {
                    onPaginateBackward()
                }
                if !config.hasReachedBottom, new.nearBottom {
                    onPaginateForward()
                }
            }
        }
        .onScrollPhaseChange { _, newPhase in
            // Ensure scroll state mutation callbacks are deferred until the
            // next main actor pass.
            Task { @MainActor in
                isUserScrolling = newPhase == .interacting || newPhase == .decelerating
                if newPhase == .idle {
                    onScrollSettled()
                }
            }
        }
        .onChange(of: visibleRowIDs) { _, newIDs in
            onBottomMostVisibleMessageChanged(rows.last(where: { newIDs.contains($0.id) })?.id)
        }
        .onChange(of: bottomInset) { _, newInset in
            scroller.updateMetrics(
                viewportHeight: scroller.viewportHeight,
                contentHeight: scroller.contentHeight,
                bottomInset: newInset
            )
        }
        .onChange(of: typingUsers) { _, newUsers in
            if isNearEndLatched {
                scroller.scrollToEnd()
            }
        }
        .onChange(of: rows.count) { _, _ in
            swipeHandler.rows = rows
        }
        .onDisappear {
            swipeHandler.stopMonitoring()
        }
        .onAppear {
            installSwipeMonitor()
        }
    }

    // MARK: - Swipe-to-Reply

    private func installSwipeMonitor() {
        swipeHandler.swipeState = swipeState
        swipeHandler.onReply = { [actions] message in
            actions.reply(message)
        }
        swipeHandler.onDismiss = { dismissSwipeActionBar() }
        swipeHandler.rows = rows
        swipeHandler.startMonitoring()
    }

    private func dismissSwipeActionBar() {
        TimelineSwipeController.dismissActionBar(swipeState)
    }

    // MARK: - Scroll Metrics

    struct ScrollMetrics: Equatable {
        // Height of the ScrollView viewport (container). Used to gate the
        // geometry callback until initial layout has a real size.
        var containerSizeHeight: CGFloat
        var contentHeight: CGFloat

        // ScrollView content is within a threshold suitable for loading newer
        // messages (forward pagination).
        var nearBottom: Bool

        // ScrollView content is within a threshold suitable for loading older
        // messages (backward pagination).
        var nearTop: Bool

        // ScrollView content is near the end (present) of the timeline and
        // should be considered loading "live" content.
        var nearEnd: Bool
    }

    // MARK: - Config

    struct TimelineConfig: Equatable {
        var showUnreadMarker: Bool
        var firstUnreadMessageID: String?
        var highlightedMessageID: String?
        var showURLPreviews: Bool
        var hasReachedBottom: Bool
        var isLive: Bool
        var isLoadingMore: Bool
    }
}
