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
final class ScrollInterceptorView: NSView {
    var onScrollDelta: ((CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?

    private var gestureAxis: GestureAxis = .undecided
    private var accumulatedDeltaX: CGFloat = 0
    private let axisLockThreshold: CGFloat = 4

    private enum GestureAxis {
        case undecided, horizontal, vertical
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let _ = self.window else { return event }
                let locationInWindow = event.locationInWindow
                let locationInView = self.convert(locationInWindow, from: nil)
                guard self.bounds.contains(locationInView) else { return event }
                self.handleScroll(with: event)
                if self.gestureAxis == .horizontal {
                    return nil
                }
                return event
            }
        } else if window == nil, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    override func removeFromSuperview() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        super.removeFromSuperview()
    }

    private func handleScroll(with event: NSEvent) {
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
