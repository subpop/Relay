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
import os
import RelayInterface
import SwiftUI

private let logger = Logger(subsystem: "Relay", category: "TimelineTableView")

/// A proxy that holds a reference to the ``TimelineTableViewController``
/// and exposes scroll actions. Used by the SwiftUI layer to trigger scrolls
/// without needing a direct reference to the view controller.
@Observable
final class TimelineTableProxy {
    weak var controller: TimelineTableViewController?

    func scrollToBottom(animated: Bool = true) {
        controller?.scrollToBottom(animated: animated)
    }

    func scrollToRow(id: String, animated: Bool = true) {
        controller?.scrollToRow(id: id, animated: animated)
    }

    /// Update the scroll view's content insets so content scrolls
    /// underneath the toolbar and compose bar.
    func setContentInsets(_ insets: NSEdgeInsets) {
        controller?.contentInsets = insets
    }

    /// Returns the event ID of the message nearest the top of the visible
    /// area, or `nil` if no rows are visible.
    ///
    /// In the unflipped table (newest = row 0 at screen bottom), the
    /// top-visible row is the highest-indexed row in the visible range.
    func topVisibleEventId() -> String? {
        controller?.topVisibleEventId()
    }

    /// The swipe state for the current table view, used by row views
    /// to render the swipe offset and reply arrow.
    var swipeState: TimelineSwipeState? {
        controller?.swipeState
    }
}

// MARK: - Bottom-Anchored Table View

/// An `NSTableView` subclass that draws from the bottom up.
///
/// By returning `false` from `isFlipped`, row 0 sits at the **bottom** of the
/// scroll view and the table grows upward. Combined with reversing the data
/// source (newest message = row 0), this gives natural bottom-anchored chat
/// behaviour: prepending older messages adds rows above the viewport without
/// shifting the scroll position.
final class BottomAnchoredTableView: NSTableView {
    override var isFlipped: Bool { false }

    /// Called after every layout pass. The timeline controller uses this to
    /// detect effective-content-width changes (column width minus horizontal
    /// safe-area insets). A safe-area change — the overlay sidebar appearing,
    /// disappearing, or resizing — re-lays the cells without resizing the
    /// scroll view or the column, so neither `viewDidResize` nor the
    /// controller's `viewDidLayout` is guaranteed to see it.
    var onLayout: (() -> Void)?

    /// Called when a live window-resize drag ends, so the controller can run
    /// the full-timeline height pass immediately instead of waiting out a
    /// debounce.
    var onLiveResizeEnd: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeEnd?()
    }

    // MARK: - Swipe-to-Reply Gesture

    /// Called with `(row, offsetX)` during a horizontal swipe.
    var onSwipeDelta: ((Int, CGFloat) -> Void)?
    /// Called with the row index when a horizontal swipe gesture ends.
    var onSwipeEnd: ((Int) -> Void)?
    /// Called when the user clicks on the table while the action bar is locked open.
    var onDismissActionBar: (() -> Void)?
    /// Whether the action bar is currently locked open (checked for left-swipe dismiss).
    var isActionBarLocked: (() -> Bool)?
    /// The current swipe offset when the action bar is locked.
    var lockedOffset: (() -> CGFloat)?

    private enum GestureAxis { case undecided, horizontal, vertical }
    private var gestureAxis: GestureAxis = .undecided
    private var accumulatedDeltaX: CGFloat = 0
    private var swipingRow: Int = -1

    override func scrollWheel(with event: NSEvent) {
        switch event.phase {
        case .began:
            gestureAxis = .undecided
            // Determine which row the cursor is over.
            let location = convert(event.locationInWindow, from: nil)
            swipingRow = row(at: location)
            // If the row is already locked, seed the accumulated delta from
            // the current offset so the swipe resumes rather than snapping
            // back to zero.
            if isActionBarLocked?() == true {
                accumulatedDeltaX = lockedOffset?() ?? 0
            } else {
                accumulatedDeltaX = 0
            }

        case .changed:
            guard swipingRow >= 0 else {
                super.scrollWheel(with: event)
                return
            }

            switch gestureAxis {
            case .undecided:
                let absX = abs(event.scrollingDeltaX)
                let absY = abs(event.scrollingDeltaY)
                if absX + absY >= TimelineSwipeController.axisLockThreshold {
                    let locked = isActionBarLocked?() ?? false
                    if absX > absY && (event.scrollingDeltaX > 0 || locked) {
                        gestureAxis = .horizontal
                        accumulatedDeltaX = max(0, accumulatedDeltaX + event.scrollingDeltaX)
                        if locked && event.scrollingDeltaX < 0 {
                            // Swiping left while locked — dismiss.
                            onDismissActionBar?()
                            gestureAxis = .undecided
                        } else {
                            onSwipeDelta?(swipingRow, TimelineSwipeController.clampedOffset(accumulatedDeltaX))
                        }
                    } else {
                        gestureAxis = .vertical
                        super.scrollWheel(with: event)
                    }
                }

            case .horizontal:
                accumulatedDeltaX += event.scrollingDeltaX
                accumulatedDeltaX = max(0, accumulatedDeltaX)
                onSwipeDelta?(swipingRow, TimelineSwipeController.clampedOffset(accumulatedDeltaX))

            case .vertical:
                super.scrollWheel(with: event)
            }

        case .ended, .cancelled:
            if gestureAxis == .horizontal {
                onSwipeEnd?(swipingRow)
            } else {
                super.scrollWheel(with: event)
            }
            gestureAxis = .undecided
            accumulatedDeltaX = 0
            swipingRow = -1

        default:
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onDismissActionBar?()
        super.mouseDown(with: event)
    }

}

// MARK: - Timeline Table View Controller

/// Manages an `NSTableView`-backed timeline that recycles `NSHostingView` cells
/// and uses `NSDiffableDataSourceSnapshot` for efficient identity-based updates.
///
/// This replaces the previous `LazyVStack`-in-`ScrollView` approach, which could
/// not recycle views and suffered from scroll position instability when content
/// was prepended.
final class TimelineTableViewController: NSViewController {

    // MARK: - Types

    enum Section { case main }

    /// Callbacks from the table view controller back to the SwiftUI layer.
    struct Callbacks {
        var onNearBottomChanged: (Bool) -> Void = { _ in }
        var onPaginateBackward: () -> Void = {}
        var onPaginateForward: () -> Void = {}
        var onMessageAppeared: (MessageRow) -> Void = { _ in }
        var onSwipeReply: (MessageRow) -> Void = { _ in }
        var makeRowView: (MessageRow, _ isNewlyAppended: Bool, _ swipeOffset: CGFloat, _ swipeIsLocked: Bool) -> TimelineRowView = { _, _, _, _ in
            fatalError("makeRowView not configured")
        }
    }

    // MARK: - Properties

    private let scrollView = NSScrollView()
    private let tableView = BottomAnchoredTableView()
    private var dataSource: NSTableViewDiffableDataSource<Section, String>?

    /// The current rows, stored in **reversed** order (newest = index 0).
    private(set) var rows: [MessageRow] = [] {
        didSet { rowIDs = rows.map(\.id) }
    }

    /// Cached identity list derived from ``rows``, updated automatically
    /// via `didSet`. Avoids repeated O(n) `.map(\.id)` allocations in
    /// ``updateRows(_:)``.
    private var rowIDs: [String] = []

    /// Whether the forward pagination sentinel should be active.
    var hasReachedEnd = true

    /// Whether the typing indicator overlay is visible. When `true`, extra
    /// bottom content inset is applied so messages scroll above the overlay.
    private(set) var typingIndicatorShown = false

    /// Observable swipe state shared with `TimelineRowView` instances.
    let swipeState = TimelineSwipeState()

    /// Additional content insets applied to the scroll view so that table
    /// content can scroll underneath overlapping SwiftUI chrome (toolbar,
    /// compose bar). Set by the representable when the safe area changes.
    var contentInsets: NSEdgeInsets = .init() {
        didSet { applyContentInsets(animated: true) }
    }

    /// Height reserved for the typing indicator overlay. Added to the
    /// bottom content inset so messages scroll above the overlay.
    private var typingInsetHeight: CGFloat = 0

    /// Applies the combined base + typing insets to the scroll view.
    private func applyContentInsets(animated: Bool) {
        var combined = contentInsets
        combined.bottom += typingInsetHeight
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                scrollView.contentInsets = combined
            }
        } else {
            scrollView.contentInsets = combined
        }
    }

    /// Updates the bottom content inset to reserve space for the typing
    /// indicator overlay when it is visible.
    private func updateTypingInset() {
        typingInsetHeight = typingIndicatorShown ? 44 : 0
        applyContentInsets(animated: true)
    }

    var callbacks = Callbacks()

    /// Guards against concurrent backward pagination requests.
    private var paginateTask: Task<Void, Never>?

    /// Whether the initial scroll to the bottom has been performed.
    private var hasScrolledToBottom = false

    /// Tracks the last column width so we can invalidate row heights on resize.
    private var lastColumnWidth: CGFloat = 0

    /// The table *column* width the rows were last measured at. Rows are measured
    /// at this width (the width the cell content actually renders at), which can
    /// change without the scroll view's frame changing — e.g. a vertical scroller
    /// appearing/disappearing, or the initial layout settling after launch.
    /// ``viewDidLayout`` watches it so those changes still trigger a re-measure.
    private var lastRenderWidth: CGFloat = 0

    /// Coalesces a live window-resize drag into one re-measure once it settles.
    private var resizeRemeasureTask: Task<Void, Never>?
    /// Coalesces bursts of text-zoom changes into one re-measure pass.
    private var textScaleRemeasureTask: Task<Void, Never>?

    /// A reusable hosting controller used to measure SwiftUI row heights
    /// for rows that don't have a live cell on screen. Only used as a
    /// fallback when no cached height exists. Wrapped in `AnyView` so the
    /// measured row can be pinned to a fixed `.frame(width:)` matching the
    /// live cell's wrap width.
    private var measurementHost: NSHostingController<AnyView>?

    /// Caches measured row heights keyed on `(messageID, roundedWidth)`.
    /// Avoids redundant `NSHostingController.sizeThatFits` calls during
    /// resize, scroll, and content-only updates.
    private var heightCache: [HeightCacheKey: CGFloat] = [:]

    private struct HeightCacheKey: Hashable {
        let messageID: String
        let width: CGFloat

        init(_ id: String, _ width: CGFloat) {
            self.messageID = id
            // Round to nearest point to avoid cache misses from sub-pixel
            // differences during live resize.
            self.width = width.rounded()
        }
    }

    /// Whether the timeline is in live mode (as opposed to focused on a
    /// specific event). When `true`, newly appended messages animate in.
    var isLive = true

    /// Message IDs that were appended at the bottom during the most recent
    /// structural update while in live mode. Row views read this set to
    /// decide whether to play an entry animation, then clear their ID
    /// after animating.
    private(set) var newlyAppendedMessageIDs: Set<String> = []

    /// Removes an ID from the newly-appended set after its entry animation
    /// has started, preventing the animation from replaying on cell reuse.
    func consumeNewlyAppended(_ id: String) {
        newlyAppendedMessageIDs.remove(id)
    }

    /// Tracks whether the user is scrolled near the bottom (newest messages).
    private var isNearBottom = true {
        didSet {
            guard isNearBottom != oldValue else { return }
            callbacks.onNearBottomChanged(isNearBottom)
        }
    }

    // MARK: - Lifecycle

    deinit {
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated {
            paginateTask?.cancel()
            remeasureDebounceTask?.cancel()
            remeasureMaxWaitTask?.cancel()
            textScaleRemeasureTask?.cancel()
            resizeRemeasureTask?.cancel()
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("timeline"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnSelection = false
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.delegate = self

        // Wire swipe-to-reply gesture from the table view.
        tableView.onSwipeDelta = { [weak self] row, offset in
            self?.handleSwipeDelta(row: row, offset: offset)
        }
        tableView.onSwipeEnd = { [weak self] row in
            self?.handleSwipeEnd(row: row)
        }
        tableView.onDismissActionBar = { [weak self] in
            guard let self, self.swipeState.isLocked else { return }
            self.dismissSwipeActionBar()
        }
        tableView.isActionBarLocked = { [weak self] in
            self?.swipeState.isLocked ?? false
        }
        tableView.lockedOffset = { [weak self] in
            self?.swipeState.offset ?? 0
        }
        tableView.onLayout = { [weak self] in
            self?.scheduleRemeasureIfEffectiveWidthChanged()
        }
        tableView.onLiveResizeEnd = { [weak self] in
            guard let self else { return }
            // The drag is over — settle the whole timeline now rather than
            // waiting out a debounce, so the release doesn't feel laggy.
            self.resizeRemeasureTask?.cancel()
            self.remeasureAllRows(reloadCells: true, dropParseCaches: false)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        view = scrollView

        configureDataSource()

        // Listen for scroll position changes.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Listen for frame changes to re-measure rows on window resize.
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewDidResize),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )

        // Link previews use a fixed-size card, so no height re-measurement
        // is needed when metadata loads.

        // Re-render and re-measure every row when the message text-zoom changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(messageTextScaleDidChange),
            name: MessageTextScale.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Data Source

    private func configureDataSource() {
        dataSource = .init(tableView: tableView) { [weak self] tableView, _, row, identifier in
            guard let self else { return NSView() }

            let messageIndex = row
            guard messageIndex >= 0, messageIndex < self.rows.count else { return NSView() }

            let messageRow = self.rows[messageIndex]
            let isNew = self.newlyAppendedMessageIDs.contains(messageRow.id)
            if isNew { self.consumeNewlyAppended(messageRow.id) }
            let swipeOffset: CGFloat = self.swipeState.swipingMessageId == messageRow.id ? self.swipeState.offset : 0
            let swipeIsLocked = self.swipeState.swipingMessageId == messageRow.id && self.swipeState.isLocked
            let rowView = self.callbacks.makeRowView(messageRow, isNew, swipeOffset, swipeIsLocked)
            let reuseID = NSUserInterfaceItemIdentifier(messageRow.message.isSystemEvent ? "system" : "message")

            let hostView: NSHostingView<TimelineRowView>
            if let recycled = tableView.makeView(withIdentifier: reuseID, owner: self)
                as? NSHostingView<TimelineRowView> {
                recycled.rootView = rowView
                hostView = recycled
            } else {
                hostView = NSHostingView(rootView: rowView)
                hostView.identifier = reuseID
                hostView.sizingOptions = [.standardBounds]
                hostView.autoresizingMask = [.width, .height]
                hostView.setContentHuggingPriority(.required, for: .vertical)
            }

            // Notify that this row appeared (for fully-read marker advancement
            // and pagination triggering).
            self.callbacks.onMessageAppeared(messageRow)

            return hostView
        }
        // Use a slide animation so the typing indicator row smoothly
        // pushes timeline content rather than snapping in with a fade.
        dataSource?.defaultRowAnimation = .slideDown
    }

    // MARK: - Updating Rows

    /// Applies a new set of rows to the table view. The rows are reversed so
    /// that newest messages sit at row 0 (the bottom of the unflipped table).
    ///
    /// Uses a fast path when only content has changed (same identity list):
    /// `reloadData(forRowIndexes:)` targets just the visible rows, avoiding a
    /// full snapshot diff.
    private static let perfSignposter = OSSignposter(
        subsystem: "app.subpop.Relay.performance",
        category: "TimelineTable"
    )

    func updateRows(_ newRows: [MessageRow], typingIndicatorShown: Bool = false) {
        // If the scroll view hasn't been laid out yet, defer until it has.
        // Applying the snapshot now would call `heightOfRow` before the
        // column has its final width, producing wildly wrong measurements.
        if scrollView.frame.width < 1 {
            DispatchQueue.main.async { [weak self] in
                self?.updateRows(newRows, typingIndicatorShown: typingIndicatorShown)
            }
            return
        }

        let updateState = Self.perfSignposter.beginInterval(
            "updateRows" as StaticString,
            "\(newRows.count) rows"
        )

        let oldTypingShown = self.typingIndicatorShown
        self.typingIndicatorShown = typingIndicatorShown
        let typingChanged = oldTypingShown != typingIndicatorShown

        // Update the typing inset immediately so the scroll view reserves
        // space for (or reclaims space from) the overlay regardless of
        // whether the row identity list changed.
        if typingChanged {
            updateTypingInset()
        }

        // Deduplicate rows by ID, keeping only the last occurrence of each
        // event (the most up-to-date version). The SDK may deliver duplicate
        // event IDs during room joins or when events arrive from multiple
        // sources. NSDiffableDataSourceSnapshot requires unique identifiers.
        let deduplicatedRows: [MessageRow]
        let reversedInput = Array(newRows.reversed())
        let inputIDs = reversedInput.map(\.id)
        if Set(inputIDs).count == inputIDs.count {
            deduplicatedRows = reversedInput
        } else {
            var seen = Set<String>()
            seen.reserveCapacity(reversedInput.count)
            deduplicatedRows = reversedInput.filter { seen.insert($0.id).inserted }
        }

        let oldRows = rows
        let oldIDs = rowIDs
        rows = deduplicatedRows
        let newIDs = rowIDs

        // Check whether the data source already has a populated snapshot.
        // When a cached view model provides rows immediately,
        // `makeNSViewController` calls `updateRows` before `loadView` has
        // run (dataSource is nil), so the snapshot is never applied.  The
        // follow-up call from `updateNSViewController` then sees
        // oldIDs == newIDs and takes the content-only fast path — but no
        // rows are visible because the snapshot is still empty.  Detecting
        // an empty snapshot here forces a full structural update.
        let snapshotIsEmpty = (dataSource?.snapshot().numberOfItems ?? 0) == 0

        if oldIDs == newIDs && !snapshotIsEmpty {
            // Content-only update (reactions, read receipts, edits).
            // Only reload visible rows whose data actually changed to
            // avoid unnecessary NSHostingView re-renders that cause
            // flickering.
            let visible = tableView.rows(in: tableView.visibleRect)
            if visible.length > 0 {
                var changedIndexes = IndexSet()
                for idx in visible.lowerBound ..< visible.upperBound {
                    guard idx < rows.count, idx < oldRows.count else { continue }
                    if rows[idx] != oldRows[idx] {
                        changedIndexes.insert(idx)
                    }
                }

                guard !changedIndexes.isEmpty else {
                    Self.perfSignposter.endInterval(
                        "updateRows" as StaticString,
                        updateState,
                        "content-only: no changes"
                    )
                    if typingChanged, isNearBottom {
                        scrollToBottom(animated: true)
                    }
                    return
                }

                let scrollBefore = scrollView.contentView.bounds.origin
                for idx in changedIndexes {
                    invalidateHeight(for: rows[idx].id)
                }
                tableView.reloadData(
                    forRowIndexes: changedIndexes,
                    columnIndexes: IndexSet(integer: 0)
                )
                tableView.noteHeightOfRows(
                    withIndexesChanged: changedIndexes
                )
                // Restore scroll position if noteHeightOfRows shifted it.
                if isNearBottom {
                    scrollToBottom(animated: false)
                } else if abs(scrollBefore.y - scrollView.contentView.bounds.origin.y) > 0.5 {
                    scrollView.contentView.scroll(to: scrollBefore)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            Self.perfSignposter.endInterval(
                "updateRows" as StaticString,
                updateState,
                "content-only update"
            )
            return
        }

        // Structural update — purge cache entries for removed message IDs.
        let removedIDs = Set(oldIDs).subtracting(newIDs)
        for id in removedIDs {
            invalidateHeight(for: id)
        }

        // Detect messages appended at the bottom (newest end) while in live
        // mode after the initial load.  These IDs are exposed to row views
        // so they can play an entry animation.
        if isLive && hasScrolledToBottom && !oldIDs.isEmpty {
            // newIDs is reversed (newest = index 0).  Walk from the front
            // and collect IDs that didn't exist in the previous snapshot.
            let oldMessageSet = Set(oldIDs)
            var appended: Set<String> = []
            for id in newIDs {
                if oldMessageSet.contains(id) { break }
                appended.insert(id)
            }
            newlyAppendedMessageIDs = appended
        } else {
            newlyAppendedMessageIDs = []
        }

        // Structural update via diffable data source.
        //
        // When more than half of the existing items are being replaced
        // (e.g. after a timeline resume delivers substantially different
        // content), animate the transition so the user sees a smooth
        // cross-fade instead of a jarring snap. Normal incremental
        // updates (pagination, new messages) keep animation disabled to
        // avoid distracting movement during regular use.
        let oldSet = Set(oldIDs)
        let overlap = oldSet.intersection(newIDs).count
        let isReplacement = !oldIDs.isEmpty && !snapshotIsEmpty
            && overlap < oldIDs.count / 2

        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newIDs, toSection: .main)
        dataSource?.apply(snapshot, animatingDifferences: isReplacement)

        Self.perfSignposter.endInterval(
            "updateRows" as StaticString,
            updateState,
            "structural: \(newIDs.count) items, \(removedIDs.count) removed, animated: \(isReplacement)"
        )

        // Re-measure visible rows after SwiftUI hosting views settle,
        // and scroll to the bottom on the first load or when the user is
        // near the bottom and new messages arrive.
        let hasNewlyAppended = !newlyAppendedMessageIDs.isEmpty
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The first rows may arrive after the initial layout passes have
            // all run (the width check refuses to latch while the table is
            // empty) — re-check now so those rows get measured at the current
            // effective width.
            self.scheduleRemeasureIfEffectiveWidthChanged()
            let visible = self.tableView.rows(in: self.tableView.visibleRect)
            if visible.length > 0 {
                self.tableView.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: visible.lowerBound ..< visible.upperBound)
                )
            }
            if !self.hasScrolledToBottom && !self.rows.isEmpty {
                self.hasScrolledToBottom = true
                self.scrollToBottom(animated: false)
            } else if hasNewlyAppended && self.isNearBottom {
                self.scrollToBottom(animated: false)
            } else if typingChanged && self.isNearBottom {
                self.scrollToBottom(animated: true)
            }
        }
    }

    // MARK: - Scroll Control

    /// Scrolls to the bottom of the timeline (newest messages).
    /// In the unflipped table, the bottom (newest) is at origin y=0,
    /// offset by the bottom content inset so the newest row sits above
    /// the compose bar.
    func scrollToBottom(animated: Bool = true) {
        let bottomPoint = NSPoint(x: 0, y: -scrollView.contentInsets.bottom)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                scrollView.contentView.setBoundsOrigin(bottomPoint)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.contentView.scroll(to: bottomPoint)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Scrolls to the row with the given message ID, centering it vertically
    /// in the visible area.
    func scrollToRow(id: String, animated: Bool = true) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let tableRow = index
        let rowRect = tableView.rect(ofRow: tableRow)
        let visibleHeight = scrollView.contentView.bounds.height
        // Center the row vertically within the visible area.
        // In the unflipped coordinate system, increasing Y is upward,
        // so we offset downward by half the visible height minus half
        // the row height to land the row in the center.
        let originY = rowRect.midY - visibleHeight / 2
        let scrollPoint = NSPoint(x: 0, y: originY)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scrollView.contentView.setBoundsOrigin(scrollPoint)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.contentView.scroll(to: scrollPoint)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Converts a table-view row index to a `rows` array index.
    private func messageIndex(forTableRow tableRow: Int) -> Int? {
        guard tableRow >= 0, tableRow < rows.count else { return nil }
        return tableRow
    }

    // MARK: - Scroll Anchor

    /// Returns the event ID of the message nearest the top of the visible
    /// area (oldest visible row), or `nil` if no rows are visible.
    func topVisibleEventId() -> String? {
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return nil }
        // In the unflipped table (newest = row 0 at bottom), the highest
        // row index in the visible range is the one nearest the screen top.
        let topIndex = visibleRange.upperBound - 1
        guard let mi = messageIndex(forTableRow: topIndex) else { return nil }
        return rows[mi].message.eventID
    }

    // MARK: - Swipe-to-Reply

    private func handleSwipeDelta(row: Int, offset: CGFloat) {
        guard let mi = messageIndex(forTableRow: row) else { return }
        // If a different row was being swiped, reset its hosting view first.
        let newID = rows[mi].message.id
        if let oldID = swipeState.swipingMessageId, oldID != newID,
           let oldRow = rows.firstIndex(where: { $0.message.id == oldID }) {
            swipeState.swipingMessageId = nil
            swipeState.offset = 0
            swipeState.isLocked = false
            updateSwipeRowView(at: oldRow)
        }
        swipeState.swipingMessageId = newID
        swipeState.offset = offset
        updateSwipeRowView(at: mi)
    }

    private func handleSwipeEnd(row: Int) {
        guard let mi = messageIndex(forTableRow: row), !rows[mi].message.isSystemEvent else {
            dismissSwipeActionBar()
            return
        }

        switch TimelineSwipeController.evaluateSwipeEnd(offset: swipeState.offset) {
        case .reply:
            dismissSwipeActionBar()
            callbacks.onSwipeReply(rows[mi])
        case .lock:
            withAnimation(.snappy(duration: 0.2)) {
                swipeState.offset = TimelineSwipeController.lockThreshold
                swipeState.isLocked = true
            }
            updateSwipeRowView(at: mi)
        case .dismiss:
            dismissSwipeActionBar()
        }
    }

    /// Dismisses the swipe action bar with animation.
    func dismissSwipeActionBar() {
        let row = rows.firstIndex(where: { $0.message.id == swipeState.swipingMessageId })
        // Update the hosting view inside the animation block so the
        // offset change is visible before the state is cleared.
        withAnimation(.snappy(duration: 0.25)) {
            swipeState.offset = 0
            swipeState.isLocked = false
            if let row { updateSwipeRowView(at: row) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.swipeState.swipingMessageId = nil
        }
    }

    /// Pushes the current swipe offset and lock state to the live hosting
    /// view for the given row. The data source closure only runs when a cell
    /// is created or recycled, so swipe state changes during the gesture
    /// must be pushed manually to the already-rendered `NSHostingView`.
    private func updateSwipeRowView(at row: Int) {
        guard row >= 0, row < rows.count,
              let hostView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? NSHostingView<TimelineRowView> else { return }
        let messageRow = rows[row]
        let offset: CGFloat = swipeState.swipingMessageId == messageRow.id ? swipeState.offset : 0
        let locked = swipeState.swipingMessageId == messageRow.id && swipeState.isLocked
        var rootView = hostView.rootView
        rootView.swipeOffset = offset
        rootView.swipeIsLocked = locked
        hostView.rootView = rootView
    }

    // MARK: - Height Cache

    /// Removes all cached heights for the given message ID (at any width).
    private func invalidateHeight(for messageID: String) {
        let beforeCount = heightCache.count
        heightCache = heightCache.filter { $0.key.messageID != messageID }
        let removed = beforeCount - heightCache.count
        if removed > 0 {
            Self.perfSignposter.emitEvent(
                "invalidateHeight" as StaticString,
                "\(messageID.prefix(8)): removed \(removed) from \(beforeCount) entries"
            )
        }
    }

    /// Message IDs awaiting a debounced height re-measure.
    private var pendingRemeasureIDs: Set<String> = []
    /// Coalesces a burst of ``remeasureRow(forMessageID:)`` calls into one pass.
    private var remeasureDebounceTask: Task<Void, Never>?
    /// Guarantees a flush even under a continuous stream of requests, so the
    /// trailing debounce can't be reset indefinitely.
    private var remeasureMaxWaitTask: Task<Void, Never>?

    /// Re-measures a row whose content height changed without any change to the
    /// underlying message data — when a collapsed system-event group is expanded
    /// or collapsed, or when a link-preview card resolves to its final size.
    ///
    /// `updateRows` only re-measures when `rows` diff, which they don't in these
    /// cases. We invalidate the row's cached height and note its new height; the
    /// measurement host rebuilds the row reading the current state, so it returns
    /// the correct height. Calls are debounced (trailing, with a max-wait) so a
    /// burst — e.g. several link-preview cards resolving at once — collapses into
    /// a single pass.
    func remeasureRow(forMessageID id: String) {
        let wasEmpty = pendingRemeasureIDs.isEmpty
        pendingRemeasureIDs.insert(id)
        // Trailing debounce: defer so the live hosting cell settles its SwiftUI
        // re-render, and so several rows changing in the same window (e.g.
        // multiple link-preview cards resolving at once) collapse into a single
        // height pass instead of one per row.
        remeasureDebounceTask?.cancel()
        remeasureDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.flushPendingRemeasures()
        }
        // Max-wait, anchored to the first queued request: a continuous stream of
        // calls can't keep resetting the trailing timer past this bound.
        if wasEmpty {
            remeasureMaxWaitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                self.flushPendingRemeasures()
            }
        }
    }

    /// Re-measures every row queued since the last flush in a single
    /// `noteHeightOfRows` pass, preserving scroll position.
    private func flushPendingRemeasures() {
        remeasureDebounceTask?.cancel()
        remeasureDebounceTask = nil
        remeasureMaxWaitTask?.cancel()
        remeasureMaxWaitTask = nil

        let ids = pendingRemeasureIDs
        pendingRemeasureIDs.removeAll()

        var indices = IndexSet()
        for id in ids {
            invalidateHeight(for: id)
            if let idx = rows.firstIndex(where: { $0.id == id }) {
                indices.insert(idx)
            }
        }
        guard !indices.isEmpty else { return }

        let scrollBefore = scrollView.contentView.bounds.origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            tableView.noteHeightOfRows(withIndexesChanged: indices)
        }
        // Preserve the scroll position; growing a row above the viewport would
        // otherwise shift the visible content.
        if isNearBottom {
            scrollToBottom(animated: false)
        } else if abs(scrollBefore.y - scrollView.contentView.bounds.origin.y) > 0.5 {
            scrollView.contentView.scroll(to: scrollBefore)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Text Zoom

    /// Timestamp of the last immediate zoom-step viewport refresh (throttle).
    private var lastZoomRefresh = Date.distantPast

    /// Responds to a text-zoom step. The chrome scales on the same frame via
    /// `@AppStorage`, so the message text lagging behind it reads as jank:
    /// drop the stale-font caches and refresh the *visible* rows immediately
    /// (throttled so holding ⌘+ doesn't re-parse the viewport at key-repeat
    /// rate). The full-timeline pass — re-parsing and re-measuring every row
    /// is main-thread work — runs once, after the burst settles. It drops the
    /// parse caches again because a throttle-skipped final step leaves
    /// intermediate-scale parses in the cache.
    @objc private func messageTextScaleDidChange() {
        if Date().timeIntervalSince(lastZoomRefresh) > 0.1 {
            lastZoomRefresh = Date()
            MessageBubbleContent.invalidateParseCaches()
            MessageTextView.invalidateSizeCaches()
            refreshVisibleRows(reloadCells: true)
        }
        textScaleRemeasureTask?.cancel()
        textScaleRemeasureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.remeasureAllRows(reloadCells: true, dropParseCaches: true)
        }
    }

    /// Re-measures every row and applies the new heights, anchoring the first
    /// visible row so the viewport keeps the same content.
    ///
    /// - Parameters:
    ///   - reloadCells: When `true`, reassigns every recycled cell's `rootView`
    ///     so its content re-lays-out from scratch. Needed on a width change:
    ///     NSTableView re-wraps visible cells live as the column changes, but a
    ///     recycled `MessageTextView` can be left wrapping at a stale (narrower)
    ///     width from mid-drag, rendering an extra line that eats the bubble
    ///     padding and clips top/bottom. A fresh render at the settled width
    ///     restores correct wrapping. (Cheap: it re-renders, it does not re-parse.)
    ///   - dropParseCaches: When `true`, also drops the parsed-text caches — only
    ///     needed when the text *content/font* changed (a text-zoom step), not on
    ///     a resize, where re-parsing every message would needlessly churn the
    ///     main thread since parsing is width-independent.
    ///
    /// The shared measurement host is discarded regardless: an
    /// `NSHostingController` re-measures on a content change but returns the
    /// previous height when only the width *proposal* changes, so reusing it
    /// across a resize would keep the old height. A fresh host measures at the
    /// new width.
    private func remeasureAllRows(reloadCells: Bool, dropParseCaches: Bool) {
        guard !rows.isEmpty else { return }
        let wasNearBottom = isNearBottom
        let anchorRow = tableView.rows(in: tableView.visibleRect).location
        let anchorOffset = anchorRow >= 0
            ? tableView.rect(ofRow: anchorRow).minY - tableView.visibleRect.minY
            : 0

        if dropParseCaches {
            MessageBubbleContent.invalidateParseCaches()
        }
        // Invalidate per-cell size caches so a cell measured narrow mid-drag
        // re-measures at the settled width instead of hugging the stale width.
        MessageTextView.invalidateSizeCaches()
        measurementHost = nil
        heightCache.removeAll()
        let all = IndexSet(integersIn: 0 ..< rows.count)
        if reloadCells {
            tableView.reloadData(forRowIndexes: all, columnIndexes: IndexSet(integer: 0))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            tableView.noteHeightOfRows(withIndexesChanged: all)
        }
        tableView.layoutSubtreeIfNeeded()

        if wasNearBottom {
            scrollToBottom(animated: false)
        } else if anchorRow >= 0, anchorRow < rows.count {
            let targetY = tableView.rect(ofRow: anchorRow).minY - anchorOffset
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Resize Handling

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleRemeasureIfEffectiveWidthChanged()
    }

    /// Re-measures every row when the *effective content width* changes — the
    /// column width minus the horizontal safe-area insets, i.e. the width the
    /// cell's SwiftUI content actually renders and wraps at.
    ///
    /// Rows are measured at this width. It can change without the scroll view's
    /// frame changing, so `viewDidResize` (which watches the scroll-view frame)
    /// misses it: a vertical scroller appearing or disappearing, the initial
    /// layout settling right after launch, and — because the table ignores safe
    /// areas and spans the full window under the overlay sidebar — the sidebar
    /// appearing, disappearing, or resizing. When that happens the visible
    /// cells re-wrap live but keep their old (too-short) measured heights,
    /// clipping the re-wrapped content — and it never self-corrects because
    /// the scroll-view frame never changes again.
    ///
    /// Called from `viewDidLayout` and from the table view's own `layout()`
    /// hook (a safe-area change re-lays the cells without laying out the
    /// controller's view). The width guard makes this a no-op on the frequent
    /// layout passes that don't change the width (scrolling, the re-measure's
    /// own `layoutSubtreeIfNeeded`), so there is no feedback loop.
    private func scheduleRemeasureIfEffectiveWidthChanged() {
        // Don't latch a width while the table is still empty: the initial rows
        // arrive after the first layout passes, and a latched width would
        // suppress the re-measure those rows need at this same width.
        guard !rows.isEmpty else { return }
        let columnWidth = tableView.tableColumns.first?.width ?? 0
        let renderWidth = columnWidth - tableView.safeAreaInsets.left - tableView.safeAreaInsets.right
        guard columnWidth > 1, renderWidth > 1, abs(renderWidth - lastRenderWidth) > 0.5 else { return }
        lastRenderWidth = renderWidth

        if tableView.inLiveResize {
            // Mid-drag: keep the *visible* rows' heights tracking the drag so
            // the resize feels live. A full-timeline pass here would re-measure
            // every row per throttle tick and stutter the drag; the full pass
            // runs once, immediately, from `viewDidEndLiveResize`.
            if Date().timeIntervalSince(lastLiveResizeRemeasure) > 0.1 {
                lastLiveResizeRemeasure = Date()
                // Defer one turn: this runs from inside the table's layout()
                // pass, and noteHeightOfRows must not re-enter layout.
                Task { @MainActor [weak self] in
                    self?.refreshVisibleRows(reloadCells: false)
                }
            }
            return
        }

        // A settled, single-shot width change (sidebar toggled or resized,
        // scroller appeared, programmatic window resize): coalesce layout
        // bursts for one frame, then run the full pass.
        resizeRemeasureTask?.cancel()
        resizeRemeasureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.remeasureAllRows(reloadCells: true, dropParseCaches: false)
        }
    }

    /// Timestamp of the last mid-drag visible-row height pass (throttle).
    private var lastLiveResizeRemeasure = Date.distantPast

    /// Lightweight refresh of just the rows currently on screen, used mid-burst
    /// (a live window-resize drag, a text-zoom step) so the viewport responds
    /// immediately while the full-timeline pass waits for the burst to end.
    ///
    /// - Parameter reloadCells: When `true`, reassigns the visible cells'
    ///   `rootView` so their content re-renders (needed when the *font* changed
    ///   on a zoom step). A resize drag passes `false`: the live cells re-wrap
    ///   on their own as the column tracks the drag, and reloading would snap
    ///   them back to a stale layout mid-drag.
    private func refreshVisibleRows(reloadCells: Bool) {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let wasNearBottom = isNearBottom
        let anchorRow = visible.location
        let anchorOffset = anchorRow >= 0
            ? tableView.rect(ofRow: anchorRow).minY - tableView.visibleRect.minY
            : 0

        // The shared host caches its height when only the width proposal
        // changes, so it must be rebuilt for the new width/scale.
        measurementHost = nil
        let upper = min(visible.upperBound, rows.count)
        guard visible.lowerBound < upper else { return }
        let indexes = IndexSet(integersIn: visible.lowerBound ..< upper)
        for idx in visible.lowerBound ..< upper {
            invalidateHeight(for: rows[idx].id)
        }
        if reloadCells {
            tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            tableView.noteHeightOfRows(withIndexesChanged: indexes)
        }
        if wasNearBottom {
            scrollToBottom(animated: false)
        } else if anchorRow >= 0, anchorRow < rows.count {
            let targetY = tableView.rect(ofRow: anchorRow).minY - anchorOffset
            let current = scrollView.contentView.bounds.origin
            if abs(current.y - targetY) > 0.5 {
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    @objc private func viewDidResize(_ notification: Notification) {
        // Use the scroll view's width: it is current the moment the frame-change
        // notification fires, whereas the column width may not have autoresized
        // yet. The deferred re-measure reads the (settled) column width.
        let newWidth = scrollView.frame.width
        guard abs(newWidth - lastColumnWidth) > 1 else { return }
        lastColumnWidth = newWidth

        // During a live drag the layout hook already tracks the width change
        // (visible rows live, full pass on drag end) — scheduling the full
        // pass here too would stutter the drag.
        guard !tableView.inLiveResize else { return }

        // NSTableView re-wraps the visible cells live as the column width
        // changes; only the row heights lag (they aren't re-queried on a width
        // change), leaving the rewrapped text clipped. Coalesce the layout
        // burst for one frame, then re-measure.
        resizeRemeasureTask?.cancel()
        resizeRemeasureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.remeasureAllRows(reloadCells: true, dropParseCaches: false)
        }
    }

    // MARK: - Scroll Detection

    @objc private func viewDidScroll(_ notification: Notification) {
        let contentBounds = scrollView.contentView.bounds
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let viewHeight = contentBounds.height

        // In an unflipped table, origin.y = 0 is the bottom.
        // The scroll offset from the bottom is simply contentBounds.origin.y.
        let distanceFromBottom = contentBounds.origin.y

        // Near-bottom detection (within ~50px of the newest messages).
        isNearBottom = distanceFromBottom < 50

        // Near-top detection (within 200px of oldest messages) for backward pagination.
        let distanceFromTop = documentHeight - viewHeight - distanceFromBottom
        if distanceFromTop < 200, paginateTask == nil {
            paginateTask = Task { [weak self] in
                self?.callbacks.onPaginateBackward()
                self?.paginateTask = nil
            }
        }

        // Forward pagination when near the bottom on a focused timeline.
        if !hasReachedEnd && distanceFromBottom < 50 {
            callbacks.onPaginateForward()
        }
    }
}

// MARK: - NSTableViewDelegate

extension TimelineTableViewController: NSTableViewDelegate {
    func selectionShouldChange(in tableView: NSTableView) -> Bool { false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let messageIndex = row
        guard messageIndex >= 0, messageIndex < rows.count else { return 44 }

        var targetWidth = tableView.tableColumns.first?.width ?? 0
        if targetWidth < 1 { targetWidth = scrollView.frame.width }
        if targetWidth < 1 { targetWidth = 600 }
        // Measure at the width the cell's SwiftUI content actually lays out at.
        // The table ignores safe areas and spans the full window, so the column
        // is wider than the visible pane; the overlay sidebar contributes a
        // leading safe-area inset that the live NSHostingView cells respect
        // when laying out their content, but a detached measurement host knows
        // nothing about. Measuring at the full column width proposes a wider
        // text wrap than the live cell uses, under-measuring the row height and
        // clipping the (more-wrapped, taller) live content top and bottom.
        targetWidth -= tableView.safeAreaInsets.left + tableView.safeAreaInsets.right

        let messageRow = rows[messageIndex]
        let cacheKey = HeightCacheKey(messageRow.id, targetWidth)

        // 1. Return a cached height if available at this width.
        if let cached = heightCache[cacheKey] {
            return cached
        }

        // 2. Fall back to the measurement host for rows without a cached
        //    value (initial load, pagination, first resize at a new width).
        let measureState = Self.perfSignposter.beginInterval(
            "heightOfRow" as StaticString,
            "cache miss: \(messageRow.id.prefix(8))"
        )
        // Pin the row to the exact cell width so the bubble wraps identically to
        // the live cell. Without the fixed frame, the row's `maxWidth: .infinity`
        // makes `sizeThatFits` return the *ideal* size — the bubble hugging its
        // content at a width that can exceed the cell's — which wraps to fewer
        // lines and under-measures the height, clipping the live (more-wrapped)
        // text's last line and the "edited" label.
        let rowView = AnyView(
            callbacks.makeRowView(messageRow, false, 0, false)
                .frame(width: targetWidth)
        )
        if let host = measurementHost {
            host.rootView = rowView
        } else {
            let host = NSHostingController(rootView: rowView)
            host.sizingOptions = [.standardBounds]
            measurementHost = host
        }

        let size = measurementHost!.sizeThatFits(in: CGSize(
            width: targetWidth,
            height: CGFloat.greatestFiniteMagnitude
        ))
        let height = max(size.height, 1)
        heightCache[cacheKey] = height
        Self.perfSignposter.endInterval(
            "heightOfRow" as StaticString,
            measureState,
            "measured: \(height)pt"
        )
        return height
    }
}
