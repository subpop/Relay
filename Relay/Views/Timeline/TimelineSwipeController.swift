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

/// Observable state for the swipe-to-reply gesture. Each ``TimelineRowView``
/// reads its own message ID to check whether it is being swiped.
@Observable
final class TimelineSwipeState {
    /// The message ID of the row currently being swiped, or `nil`.
    var swipingMessageId: String?
    /// The current horizontal offset of the swipe gesture.
    var offset: CGFloat = 0
    /// When `true`, the action bar is locked open and awaiting a button tap.
    var isLocked = false
}

/// Shared swipe-to-reply gesture logic used by the SwiftUI timeline renderer.
///
/// ``SwipeScrollHandler`` detects scroll-wheel events and delegates to this
/// controller for axis locking, offset clamping, swipe-end evaluation, and
/// action bar dismissal.
@MainActor
enum TimelineSwipeController {

    // MARK: - Constants

    /// Minimum combined delta before the gesture axis is decided.
    static let axisLockThreshold: CGFloat = 4

    /// Offset at which the action bar locks open on swipe end.
    static let lockThreshold: CGFloat = 60

    /// Offset at which the reply action triggers immediately on swipe end.
    static let triggerThreshold: CGFloat = 100

    /// Maximum visual offset (rubber-band limit).
    static let maxOffset: CGFloat = 120

    // MARK: - Offset Clamping

    /// Applies rubber-band clamping past the trigger threshold: linear up
    /// to ``triggerThreshold``, then 30% of excess capped at ``maxOffset``.
    static func clampedOffset(_ delta: CGFloat) -> CGFloat {
        if delta <= triggerThreshold {
            return delta
        }
        let excess = delta - triggerThreshold
        return min(triggerThreshold + excess * 0.3, maxOffset)
    }

    // MARK: - Swipe End Evaluation

    /// The action to take when a horizontal swipe gesture ends.
    enum SwipeEndAction {
        /// The swipe exceeded the trigger threshold — fire the reply.
        case reply
        /// The swipe exceeded the lock threshold — lock the action bar open.
        case lock
        /// The swipe was too short — dismiss with no action.
        case dismiss
    }

    /// Evaluates the current swipe offset and returns the appropriate action.
    static func evaluateSwipeEnd(offset: CGFloat) -> SwipeEndAction {
        if offset >= triggerThreshold {
            return .reply
        } else if offset >= lockThreshold {
            return .lock
        } else {
            return .dismiss
        }
    }

    // MARK: - Action Bar Dismissal

    /// Animates the action bar closed and clears the swiping message ID
    /// after the animation completes.
    static func dismissActionBar(_ swipeState: TimelineSwipeState) {
        withAnimation(.snappy(duration: 0.25)) {
            swipeState.offset = 0
            swipeState.isLocked = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            swipeState.swipingMessageId = nil
        }
    }
}

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