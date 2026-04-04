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

// MARK: - Swipe Offset Environment

private struct SwipeOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The current horizontal swipe offset applied by ``MessageSwipeActions``.
    /// Child views can read this to render swipe-dependent UI (e.g. a reply arrow).
    var swipeOffset: CGFloat {
        get { self[SwipeOffsetKey.self] }
        set { self[SwipeOffsetKey.self] = newValue }
    }
}

/// Wraps a message view with a horizontal swipe gesture that triggers a reply action,
/// matching the Apple Messages interaction model.
///
/// Uses an AppKit `NSView` overlay to intercept horizontal `scrollWheel` events from
/// two-finger trackpad swipes before the parent `ScrollView` consumes them.
///
/// The swipe offset is published via the ``SwiftUI/EnvironmentValues/swipeOffset``
/// environment value so that child views (e.g. ``MessageView``) can position a reply
/// arrow relative to the bubble they own.
struct MessageSwipeActions<Content: View>: View {
    /// The message content to display (typically a ``MessageView``).
    @ViewBuilder let content: () -> Content

    /// Called when the user completes a full swipe past the trigger threshold.
    var onReply: (() -> Void)?

    // MARK: - Gesture state

    /// The drag distance required to trigger the reply action.
    private let triggerThreshold: CGFloat = 40

    /// Maximum offset allowed — provides rubber-band resistance beyond the trigger.
    private let maxOffset: CGFloat = 100

    /// Current horizontal translation of the message.
    @State private var offsetX: CGFloat = 0

    var body: some View {
        content()
            .environment(\.swipeOffset, offsetX)
            .offset(x: offsetX)
            .overlay {
                HorizontalScrollInterceptor(
                    onScrollDelta: handleScrollDelta,
                    onScrollEnd: handleScrollEnd
                )
            }
    }

    // MARK: - Scroll Event Handling

    private func handleScrollDelta(_ deltaX: CGFloat) {
        if deltaX <= triggerThreshold {
            offsetX = deltaX
        } else {
            let excess = deltaX - triggerThreshold
            let rubberBanded = triggerThreshold + excess * 0.3
            offsetX = min(rubberBanded, maxOffset)
        }
    }

    private func handleScrollEnd() {
        let shouldTrigger = offsetX >= triggerThreshold
        withAnimation(.snappy(duration: 0.25)) {
            offsetX = 0
        }
        if shouldTrigger {
            onReply?()
        }
    }
}

// MARK: - Horizontal Scroll Interceptor (AppKit)

/// An `NSViewRepresentable` that places an invisible `NSView` over the message content to
/// intercept horizontal `scrollWheel` events from two-finger trackpad swipes.
///
/// When the initial scroll direction is predominantly horizontal and rightward, this view
/// captures the gesture and reports deltas. Vertical-dominant or leftward scrolls are
/// passed through to the parent `ScrollView` for normal timeline scrolling.
private struct HorizontalScrollInterceptor: NSViewRepresentable {
    let onScrollDelta: (CGFloat) -> Void
    let onScrollEnd: () -> Void

    func makeNSView(context: Context) -> ScrollInterceptorView {
        let view = ScrollInterceptorView()
        view.onScrollDelta = onScrollDelta
        view.onScrollEnd = onScrollEnd
        return view
    }

    func updateNSView(_ nsView: ScrollInterceptorView, context: Context) {
        nsView.onScrollDelta = onScrollDelta
        nsView.onScrollEnd = onScrollEnd
    }
}

/// The AppKit view that performs the actual scroll-wheel interception.
///
/// Instead of each instance installing its own `NSEvent` monitor (which scales
/// as O(visible-messages) per scroll event), instances register with a shared
/// ``SwipeScrollMonitor`` that maintains a single global monitor and dispatches
/// to the hit-tested view.
final class ScrollInterceptorView: NSView {
    var onScrollDelta: ((CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?

    var gestureAxis: GestureAxis = .undecided
    var accumulatedDeltaX: CGFloat = 0
    let axisLockThreshold: CGFloat = 4

    enum GestureAxis {
        case undecided, horizontal, vertical
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            SwipeScrollMonitor.shared.register(self)
        } else {
            SwipeScrollMonitor.shared.unregister(self)
        }
    }

    override func removeFromSuperview() {
        SwipeScrollMonitor.shared.unregister(self)
        super.removeFromSuperview()
    }

    // swiftlint:disable:next cyclomatic_complexity
    func handleScroll(with event: NSEvent) {
        switch event.phase {
        case .began:
            gestureAxis = .undecided
            accumulatedDeltaX = 0

        case .changed:
            switch gestureAxis {
            case .undecided:
                let absX = abs(event.scrollingDeltaX)
                let absY = abs(event.scrollingDeltaY)
                let total = absX + absY

                if total >= axisLockThreshold {
                    if absX > absY {
                        let delta = event.scrollingDeltaX
                        if delta > 0 || accumulatedDeltaX > 0 {
                            gestureAxis = .horizontal
                            accumulatedDeltaX += delta
                            accumulatedDeltaX = max(0, accumulatedDeltaX)
                            onScrollDelta?(accumulatedDeltaX)
                        } else {
                            gestureAxis = .vertical
                        }
                    } else {
                        gestureAxis = .vertical
                    }
                }

            case .horizontal:
                let delta = event.scrollingDeltaX
                accumulatedDeltaX += delta
                accumulatedDeltaX = max(0, accumulatedDeltaX)
                onScrollDelta?(accumulatedDeltaX)

            case .vertical:
                break
            }

        case .ended, .cancelled:
            if gestureAxis == .horizontal {
                onScrollEnd?()
            }
            gestureAxis = .undecided
            accumulatedDeltaX = 0

        default:
            break
        }
    }
}

// MARK: - Shared Scroll Monitor

/// Maintains a single global `NSEvent` scroll-wheel monitor and dispatches
/// events to the appropriate ``ScrollInterceptorView`` based on hit-testing.
///
/// This replaces the previous pattern where each visible message installed its
/// own monitor, causing O(N) coordinate conversions per scroll event.
private final class SwipeScrollMonitor {
    static let shared = SwipeScrollMonitor()

    private var registeredViews = NSHashTable<ScrollInterceptorView>.weakObjects()
    private var monitor: Any?
    /// The view that "owns" the current scroll gesture (locked on `.began`).
    private weak var activeView: ScrollInterceptorView?

    private init() {}

    func register(_ view: ScrollInterceptorView) {
        registeredViews.add(view)
        installMonitorIfNeeded()
    }

    func unregister(_ view: ScrollInterceptorView) {
        registeredViews.remove(view)
        if activeView === view {
            activeView = nil
        }
        if registeredViews.count == 0, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.dispatch(event)
        }
    }

    private func dispatch(_ event: NSEvent) -> NSEvent? {
        if event.phase == .began {
            // Lock to the topmost interceptor under the cursor for this gesture.
            activeView = nil
            for view in registeredViews.allObjects {
                guard view.window != nil else { continue }
                let locationInView = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(locationInView) else { continue }
                activeView = view
                break
            }
        }

        guard let target = activeView else { return event }

        // Verify the target is still under the cursor (in case of fast scrolling).
        let locationInView = target.convert(event.locationInWindow, from: nil)
        guard target.bounds.contains(locationInView) else {
            if event.phase == .ended || event.phase == .cancelled {
                activeView = nil
            }
            return event
        }

        target.handleScroll(with: event)
        if target.gestureAxis == .horizontal {
            if event.phase == .ended || event.phase == .cancelled {
                activeView = nil
            }
            return nil
        }

        if event.phase == .ended || event.phase == .cancelled {
            activeView = nil
        }
        return event
    }
}
