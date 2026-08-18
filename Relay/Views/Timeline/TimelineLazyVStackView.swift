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
import RelayInterface
import SwiftUI

/// SwiftUI-native timeline renderer used by the Labs LazyVStack experiment.
///
/// Messages are rendered in natural order (oldest first) inside a `LazyVStack`
/// with role-specific scroll anchors: `.initialOffset(.bottom)` positions the
/// viewport at the newest messages on first load, and `.sizeChanges(.bottom)`
/// keeps the bottom edge pinned when content size changes (back-pagination or
/// new messages). A `ScrollPosition` binding enables programmatic
/// scroll-to-bottom and scroll-to-row from the parent ``TimelineView``.
///
/// Read receipt advancement uses `onScrollTargetVisibilityChange` to track
/// which messages are actually visible, rather than per-row `.onAppear`
/// callbacks which fire during cell creation and may not reflect true
/// visibility.  Back-pagination is gated on `onScrollPhaseChange` so it only
/// triggers during active user scrolling, preventing runaway re-triggers
/// from content-size geometry updates.
struct TimelineLazyVStackView: View {
    /// Shared configuration common to both renderers.
    let config: TimelineRendererConfig
    /// Shared callbacks common to both renderers.
    let callbacks: TimelineRendererCallbacks

    /// The consolidated timeline interaction callbacks.
    let actions: TimelineActions

    // MARK: - Per-Row Bool Helpers

    /// Whether this row should show the unread divider marker.
    /// Pre-computed per-row so only the affected row's equality changes.
    private func isUnreadDivider(for row: MessageRow) -> Bool {
        config.showUnreadMarker && row.message.id == config.firstUnreadMessageId
    }

    /// Whether this row is currently highlighted (e.g. after scrolling to
    /// a reply). Pre-computed per-row so only the highlighted row's
    /// equality changes.
    private func isHighlighted(for row: MessageRow) -> Bool {
        config.highlightedMessageId == row.message.eventID
    }

    /// Called when the set of visible message IDs changes, as reported by
    /// `onScrollTargetVisibilityChange`. Used for fully-read marker
    /// advancement instead of per-row `.onAppear` callbacks, which fire
    /// during cell creation rather than true visibility.
    var onVisibleMessagesChanged: ([String]) -> Void = { _ in }

    /// Called when the scroll view transitions to the `.idle` phase after
    /// scrolling or a programmatic animation completes. Used to re-evaluate
    /// read receipt state after pagination-induced geometry changes settle.
    var onScrollSettled: () -> Void = {}

    /// Whether the view model is currently loading more history. Used to
    /// prevent the scroll geometry handler from re-triggering backward
    /// pagination while the SDK is still processing a previous request.
    var isLoadingMore: Bool = false

    /// The view model, used by the typing indicator injector to observe
    /// typing state without invalidating the renderer's own body.
    let viewModel: any TimelineStateProviding

    /// Extra bottom margin so content clears the compose bar overlay.
    var bottomContentMargin: CGFloat = 0

    @Binding var scrollPosition: ScrollPosition

    // MARK: - Private State

    @State private var swipeState = TimelineSwipeState()
    @State private var swipeHandler = SwipeScrollHandler()
    @State private var isUserScrolling = false
    @State private var previousLastRowID: String?
    @State private var initialLoadComplete = false

    /// The ID of the row currently playing an entry animation, or `nil`.
    /// Set when a new message is appended and auto-cleared after the
    /// animation duration so only the single new row is invalidated.
    @State private var newlyAppendedID: String?

    /// Sticky-bottom latch: once the user is near the bottom, stays
    /// `true` until the user **actively** scrolls away. Content growth
    /// (new messages, pagination) does not unlatch. This prevents
    /// transient geometry changes during content insertion from
    /// spoiling the near-bottom state and causing missed auto-scrolls.
    @State private var isNearBottomLatched = true

    /// IDs of rows currently visible in the scroll viewport, tracked via
    /// per-row `onScrollVisibilityChange`. Used to advance the read marker.
    @State private var visibleRowIDs: Set<String> = []

    /// Delays per-row visibility tracking until the initial scroll position
    /// and content margins have settled. Without this, `onScrollVisibilityChange`
    /// fires for every visible row during initial layout, triggering state
    /// mutations that interfere with the scroll anchor positioning.
    @State private var visibilityTrackingEnabled = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(config.rows) { row in
                    TimelineRowView(
                        row: row,
                        isNewlyAppended: row.id == newlyAppendedID,
                        isHighlighted: isHighlighted(for: row),
                        isUnreadDivider: isUnreadDivider(for: row),
                        showURLPreviews: config.showURLPreviews,
                        onAppear: { _ in },
                        swipeOffset: swipeState.swipingMessageId == row.id ? swipeState.offset : 0,
                        swipeIsLocked: swipeState.swipingMessageId == row.id && swipeState.isLocked
                    )
                    .equatable()
                    .id(row.id)
                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                        guard visibilityTrackingEnabled else { return }
                        if visible {
                            visibleRowIDs.insert(row.id)
                        } else {
                            visibleRowIDs.remove(row.id)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: swipeHandler.hoveredRowID = row.id
                        case .ended: if swipeHandler.hoveredRowID == row.id { swipeHandler.hoveredRowID = nil }
                        }
                    }
                }

                // Animated spacer that opens/closes space for the
                // typing indicator overlay without affecting contentMargins.
                Color.clear
                    .frame(height: config.typingIndicatorShown ? 44 : 0)
                    .animation(.easeInOut(duration: 0.25), value: config.typingIndicatorShown)
            }

        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .environment(\.timelineActions, actions)
        .onTapGesture {
            if swipeState.isLocked { dismissSwipeActionBar() }
        }
        .contentMargins(.bottom, bottomContentMargin, for: .scrollContent)
        .contentMargins(.bottom, bottomContentMargin, for: .scrollIndicators)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            // Measure distance from the last actual content, ignoring the
            // bottom content inset (compose bar dead space). Using
            // contentSize rather than contentSize + contentInsets.bottom
            // means we're checking proximity to real messages, not padding.
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
            let distanceFromContent = max(0, geometry.contentSize.height - visibleBottom)
            return ScrollMetrics(
                nearBottom: distanceFromContent < 100,
                nearTop: geometry.contentOffset.y < 600,
                nearEnd: distanceFromContent < 50
            )
        } action: { old, new in
            // Sticky-bottom latch: when the raw geometry says "near
            // bottom", latch on. Only unlatch when the *user* actively
            // scrolls away (not content-growth geometry shifts).
            if new.nearBottom {
                if !isNearBottomLatched {
                    isNearBottomLatched = true
                    callbacks.onNearBottomChanged(true)
                }
            } else if isUserScrolling {
                // User is actively scrolling away from bottom.
                if isNearBottomLatched {
                    isNearBottomLatched = false
                    callbacks.onNearBottomChanged(false)
                }
            }
            // Content growth while not scrolling: keep the latch as-is.

            // Only trigger backward pagination when the user is actively
            // scrolling and the SDK isn't already loading. This prevents
            // runaway re-triggers from content-size-change geometry
            // updates during pagination bursts.
            if new.nearTop, !config.rows.isEmpty, !isLoadingMore, isUserScrolling {
                callbacks.onPaginateBackward()
            }
            if !config.hasReachedEnd, new.nearEnd {
                callbacks.onPaginateForward()
            }
        }
        .scrollPosition($scrollPosition, anchor: .bottom)
        .onScrollPhaseChange { _, newPhase in
            isUserScrolling = newPhase == .interacting || newPhase == .decelerating
            if newPhase == .idle {
                onScrollSettled()
            }
        }
        .onChange(of: visibleRowIDs) { _, newIDs in
            // Report visible IDs in row order (oldest → newest) so the
            // caller can advance the read marker to the last element.
            let ordered = config.rows.compactMap { newIDs.contains($0.id) ? $0.id : nil }
            onVisibleMessagesChanged(ordered)
        }
        .onAppear {
            installSwipeMonitor()
            swipeHandler.rows = config.rows
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                initialLoadComplete = true
                visibilityTrackingEnabled = true
            }
        }
        .onDisappear { swipeHandler.stopMonitoring() }
        .onChange(of: config.rows.count) {
            swipeHandler.rows = config.rows
        }
        .onChange(of: config.rows.last?.id) {
            // Deferred by one run-loop turn to avoid mutating @State
            // during the same layout pass that triggered this onChange.
            Task { @MainActor in
                let newLastID = config.rows.last?.id

                // Determine if this is a genuinely new message appended
                // to the end (not the initial load or a pagination).
                if config.isLive, initialLoadComplete,
                   let newLastID, newLastID != previousLastRowID {
                    newlyAppendedID = newLastID

                    // Auto-clear after the entry animation completes so
                    // subsequent ForEach evaluations find nil and don't
                    // invalidate this row again.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        if newlyAppendedID == newLastID {
                            newlyAppendedID = nil
                        }
                    }
                }

                previousLastRowID = newLastID
            }
        }
    }

    // MARK: - Swipe Monitor

    private func installSwipeMonitor() {
        swipeHandler.swipeState = swipeState
        swipeHandler.onReply = { [actions] message in
            actions.reply(message)
        }
        swipeHandler.onDismiss = { dismissSwipeActionBar() }
        swipeHandler.startMonitoring()
    }

    private func dismissSwipeActionBar() {
        TimelineSwipeController.dismissActionBar(swipeState)
    }
}

// MARK: - Scroll Metrics

/// Combined scroll geometry values derived in a single
/// `onScrollGeometryChange` pass to avoid the "multiple updates per frame"
/// warning that occurs when using separate modifiers.
///
/// All fields are threshold-based booleans rather than raw `CGFloat`
/// values. This prevents sub-pixel geometry fluctuations (e.g. during
/// an inspector resize) from producing "new" `ScrollMetrics` that
/// re-trigger the action with identical logical state, which causes
/// "Geometry action is cycling between duplicate values" warnings.
private struct ScrollMetrics: Equatable {
    /// Whether the scroll position is within 100pt of the content bottom.
    var nearBottom: Bool
    /// Whether the scroll offset is within the backward-pagination zone.
    var nearTop: Bool
    /// Whether the scroll position is within 50pt of the content end
    /// (forward-pagination zone).
    var nearEnd: Bool
}

// MARK: - Swipe Scroll Handler

/// Monitors local scroll wheel events for horizontal two-finger swipe
/// gestures. When a horizontal swipe is detected, it drives the
/// ``TimelineSwipeState`` for swipe-to-reply; vertical scrolls are ignored
/// (passed through to the underlying `ScrollView`).
///
/// When the handler locks onto a horizontal gesture, it synthesizes a
/// `.cancelled` scroll wheel event and dispatches it to the window's
/// first responder so the underlying `NSScrollView` cleanly exits its
/// tracking loop. Subsequent horizontal events are consumed (returned
/// as `nil` from the monitor) so they never reach the scroll view.
@MainActor
final class SwipeScrollHandler {
    var swipeState = TimelineSwipeState()
    var hoveredRowID: String?
    var rows: [MessageRow] = [] {
        didSet { rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.message.id, $0) }) }
    }
    private var rowsByID: [String: MessageRow] = [:]
    var onReply: (TimelineMessage) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    private var scrollMonitor: Any?

    private enum GestureAxis { case undecided, horizontal, vertical }
    private var gestureAxis: GestureAxis = .undecided
    private var accumulatedDeltaX: CGFloat = 0
    private var swipingMessageID: String?

    func startMonitoring() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollWheel(event)
        }
    }

    func stopMonitoring() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stopMonitoring()
        }
    }

    /// Returns `nil` to consume the event, or the event itself to pass it through.
    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        switch event.phase {
        case .began:
            gestureAxis = .undecided
            swipingMessageID = hoveredRowID
            // If the row is already locked, seed the accumulated delta from
            // the current offset so the swipe resumes rather than snapping
            // back to zero.
            if swipeState.isLocked, swipingMessageID == swipeState.swipingMessageId {
                accumulatedDeltaX = swipeState.offset
            } else {
                accumulatedDeltaX = 0
            }
            return event

        case .changed:
            guard swipingMessageID != nil else { return event }

            switch gestureAxis {
            case .undecided:
                let absX = abs(event.scrollingDeltaX)
                let absY = abs(event.scrollingDeltaY)
                guard absX + absY >= TimelineSwipeController.axisLockThreshold else { return event }

                let locked = swipeState.isLocked
                if absX > absY && (event.scrollingDeltaX > 0 || locked) {
                    gestureAxis = .horizontal
                    accumulatedDeltaX = max(0, accumulatedDeltaX + event.scrollingDeltaX)
                    if locked && event.scrollingDeltaX < 0 {
                        onDismiss()
                        gestureAxis = .undecided
                        return nil
                    }
                    applyDelta()
                    // Cancel the ScrollView's active tracking so it doesn't
                    // fight with our horizontal gesture.
                    sendCancellation(for: event)
                    return nil
                } else {
                    gestureAxis = .vertical
                    return event
                }

            case .horizontal:
                accumulatedDeltaX += event.scrollingDeltaX
                accumulatedDeltaX = max(0, accumulatedDeltaX)
                applyDelta()
                return nil

            case .vertical:
                return event
            }

        case .ended, .cancelled:
            let wasHorizontal = gestureAxis == .horizontal
            if wasHorizontal { handleSwipeEnd() }
            resetGesture()
            if wasHorizontal {
                // Send a cancellation so the ScrollView doesn't linger in
                // an active tracking state.
                sendCancellation(for: event)
                return nil
            }
            return event

        default:
            return event
        }
    }

    /// Synthesizes a `.cancelled` scroll wheel event with zeroed deltas and
    /// dispatches it directly to the key window so the underlying
    /// `NSScrollView` cleanly exits any active scroll tracking.
    private func sendCancellation(for original: NSEvent) {
        guard let cgEvent = original.cgEvent?.copy(),
              let window = original.window else { return }
        // Phase 4 = kCGScrollPhaseCancelled.
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: 0)
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        if let cancelEvent = NSEvent(cgEvent: cgEvent) {
            window.sendEvent(cancelEvent)
        }
    }

    private func applyDelta() {
        guard let id = swipingMessageID else { return }
        let row = rowsByID[id]
        guard row?.message.isSystemEvent != true else { return }

        if swipeState.isLocked {
            swipeState.isLocked = false
        }
        swipeState.swipingMessageId = id
        swipeState.offset = TimelineSwipeController.clampedOffset(accumulatedDeltaX)
    }

    private func handleSwipeEnd() {
        guard let id = swipingMessageID else {
            onDismiss()
            return
        }
        guard let row = rowsByID[id],
              !row.message.isSystemEvent else {
            onDismiss()
            return
        }

        switch TimelineSwipeController.evaluateSwipeEnd(offset: swipeState.offset) {
        case .reply:
            onDismiss()
            onReply(row.message)
        case .lock:
            withAnimation(.snappy(duration: 0.2)) {
                swipeState.offset = TimelineSwipeController.lockThreshold
                swipeState.isLocked = true
            }
        case .dismiss:
            onDismiss()
        }
    }

    private func resetGesture() {
        gestureAxis = .undecided
        accumulatedDeltaX = 0
        swipingMessageID = nil
    }
}


