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
import OSLog
import os
import RelayInterface
import SwiftUI

private let logger = Logger(subsystem: "Relay", category: "TimelineTableView")

/// Observable state for the swipe-to-reply gesture on the table view.
/// The table view controller updates this during the gesture; each
/// `TimelineRowView` reads its own message ID to check if it's being swiped.
@Observable
final class TimelineSwipeState {
    /// The message ID of the row currently being swiped, or `nil`.
    var swipingMessageId: String?
    /// The current horizontal offset of the swipe gesture.
    var offset: CGFloat = 0
}

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

    // MARK: - Swipe-to-Reply Gesture

    /// Called with `(row, offsetX)` during a horizontal swipe.
    var onSwipeDelta: ((Int, CGFloat) -> Void)?
    /// Called with the row index when a horizontal swipe gesture ends.
    var onSwipeEnd: ((Int) -> Void)?

    private enum GestureAxis { case undecided, horizontal, vertical }
    private var gestureAxis: GestureAxis = .undecided
    private var accumulatedDeltaX: CGFloat = 0
    private var swipingRow: Int = -1
    private let axisLockThreshold: CGFloat = 4
    private let triggerThreshold: CGFloat = 40
    private let maxOffset: CGFloat = 100

    override func scrollWheel(with event: NSEvent) {
        switch event.phase {
        case .began:
            gestureAxis = .undecided
            accumulatedDeltaX = 0
            // Determine which row the cursor is over.
            let location = convert(event.locationInWindow, from: nil)
            swipingRow = row(at: location)

        case .changed:
            guard swipingRow >= 0 else {
                super.scrollWheel(with: event)
                return
            }

            switch gestureAxis {
            case .undecided:
                let absX = abs(event.scrollingDeltaX)
                let absY = abs(event.scrollingDeltaY)
                if absX + absY >= axisLockThreshold {
                    if absX > absY && event.scrollingDeltaX > 0 {
                        gestureAxis = .horizontal
                        accumulatedDeltaX = max(0, event.scrollingDeltaX)
                        onSwipeDelta?(swipingRow, clampedOffset(accumulatedDeltaX))
                    } else {
                        gestureAxis = .vertical
                        super.scrollWheel(with: event)
                    }
                }

            case .horizontal:
                accumulatedDeltaX += event.scrollingDeltaX
                accumulatedDeltaX = max(0, accumulatedDeltaX)
                onSwipeDelta?(swipingRow, clampedOffset(accumulatedDeltaX))

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

    private func clampedOffset(_ delta: CGFloat) -> CGFloat {
        if delta <= triggerThreshold {
            return delta
        }
        let excess = delta - triggerThreshold
        return min(triggerThreshold + excess * 0.3, maxOffset)
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
        var makeRowView: (MessageRow, _ isNewlyAppended: Bool) -> TimelineRowView = { _, _ in
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

    /// Observable swipe state shared with `TimelineRowView` instances.
    let swipeState = TimelineSwipeState()

    /// Additional content insets applied to the scroll view so that table
    /// content can scroll underneath overlapping SwiftUI chrome (toolbar,
    /// compose bar). Set by the representable when the safe area changes.
    var contentInsets: NSEdgeInsets = .init() {
        didSet {
            scrollView.contentInsets = contentInsets
        }
    }

    var callbacks = Callbacks()

    /// Guards against concurrent backward pagination requests.
    private var paginateTask: Task<Void, Never>?

    /// Whether the initial scroll to the bottom has been performed.
    private var hasScrolledToBottom = false

    /// Tracks the last column width so we can invalidate row heights on resize.
    private var lastColumnWidth: CGFloat = 0

    /// Coalesces rapid resize events so only the final one runs.
    private var resizeWorkItem: DispatchWorkItem?

    /// A reusable hosting controller used to measure SwiftUI row heights
    /// for rows that don't have a live cell on screen. Only used as a
    /// fallback when no cached height exists. Using the concrete
    /// ``TimelineRowView`` type avoids `AnyView` type-erasure overhead
    /// and lets SwiftUI reuse the internal view hierarchy between measurements.
    private var measurementHost: NSHostingController<TimelineRowView>?

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
    }

    // MARK: - Data Source

    private func configureDataSource() {
        dataSource = .init(tableView: tableView) { [weak self] tableView, _, row, _ in
            guard let self, row < self.rows.count else { return NSView() }

            let messageRow = self.rows[row]
            let isNew = self.newlyAppendedMessageIDs.contains(messageRow.id)
            if isNew { self.consumeNewlyAppended(messageRow.id) }
            let rowView = self.callbacks.makeRowView(messageRow, isNew)
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

    func updateRows(_ newRows: [MessageRow]) {
        // If the scroll view hasn't been laid out yet, defer until it has.
        // Applying the snapshot now would call `heightOfRow` before the
        // column has its final width, producing wildly wrong measurements.
        if scrollView.frame.width < 1 {
            DispatchQueue.main.async { [weak self] in
                self?.updateRows(newRows)
            }
            return
        }

        let updateState = Self.perfSignposter.beginInterval(
            "updateRows" as StaticString,
            "\(newRows.count) rows"
        )

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
                for idx in visible.lowerBound ..< visible.upperBound
                    where idx < rows.count && idx < oldRows.count {
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
            let oldSet = Set(oldIDs)
            // newIDs is reversed (newest = index 0).  Walk from the front
            // and collect IDs that didn't exist in the previous snapshot.
            var appended: Set<String> = []
            for id in newIDs {
                if oldSet.contains(id) { break }
                appended.insert(id)
            }
            newlyAppendedMessageIDs = appended
        } else {
            newlyAppendedMessageIDs = []
        }

        // Structural update via diffable data source.
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newIDs, toSection: .main)
        dataSource?.apply(snapshot, animatingDifferences: false)

        Self.perfSignposter.endInterval(
            "updateRows" as StaticString,
            updateState,
            "structural: \(newIDs.count) items, \(removedIDs.count) removed"
        )

        // Re-measure visible rows after SwiftUI hosting views settle,
        // and scroll to the bottom on the first load.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let visible = self.tableView.rows(in: self.tableView.visibleRect)
            if visible.length > 0 {
                self.preCacheHeights(for: visible)
                self.tableView.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: visible.lowerBound ..< visible.upperBound)
                )
            }
            if !self.hasScrolledToBottom && !self.rows.isEmpty {
                self.hasScrolledToBottom = true
                self.scrollToBottom(animated: false)
            }
        }
    }

    // MARK: - Scroll Control

    /// Scrolls to the bottom of the timeline (newest messages).
    /// In the unflipped table, the bottom (newest) is at origin y=0,
    /// offset by the bottom content inset so the newest row sits above
    /// the compose bar.
    func scrollToBottom(animated: Bool = true) {
        let bottomPoint = NSPoint(x: 0, y: -contentInsets.bottom)
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
        let rowRect = tableView.rect(ofRow: index)
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

    // MARK: - Swipe-to-Reply

    private func handleSwipeDelta(row: Int, offset: CGFloat) {
        guard row >= 0, row < rows.count else { return }
        swipeState.swipingMessageId = rows[row].message.id
        swipeState.offset = offset
    }

    private func handleSwipeEnd(row: Int) {
        let triggerThreshold: CGFloat = 40
        let triggered = swipeState.offset >= triggerThreshold

        // Animate the offset back to zero.
        withAnimation(.snappy(duration: 0.25)) {
            swipeState.offset = 0
        }
        // Clear the swiping ID after the animation settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.swipeState.swipingMessageId = nil
        }

        if triggered, row >= 0, row < rows.count, !rows[row].message.isSystemEvent {
            callbacks.onSwipeReply(rows[row])
        }
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

    /// Walks visible live cells and writes their current `fittingSize` into
    /// the height cache. Call this *outside* of `heightOfRow` (e.g. from a
    /// deferred block) so that the subsequent `noteHeightOfRows` can return
    /// cached values without hitting the measurement host.
    private func preCacheHeights(for visible: NSRange) {
        var targetWidth = tableView.tableColumns.first?.width ?? 0
        if targetWidth < 1 { targetWidth = scrollView.frame.width }
        let roundedWidth = targetWidth.rounded()

        for idx in visible.lowerBound ..< visible.upperBound where idx < rows.count {
            if let cell = tableView.view(atColumn: 0, row: idx, makeIfNecessary: false)
                as? NSHostingView<TimelineRowView> {
                let h = cell.fittingSize.height
                if h > 0 {
                    heightCache[HeightCacheKey(rows[idx].id, roundedWidth)] = h
                }
            }
        }
    }

    // MARK: - Resize Handling

    @objc private func viewDidResize(_ notification: Notification) {
        let newWidth = tableView.tableColumns.first?.width ?? scrollView.frame.width
        guard abs(newWidth - lastColumnWidth) > 1 else { return }
        lastColumnWidth = newWidth

        // Capture whether the user is at the bottom before heights change.
        let wasNearBottom = isNearBottom

        // Defer the height update so that live NSHostingView cells have
        // time to re-layout their SwiftUI content at the new column width.
        // On the next run-loop pass we walk the visible cells, read their
        // `fittingSize` (which now reflects the new width), and pre-populate
        // the height cache. Then `noteHeightOfRows` triggers `heightOfRow`
        // which returns the cached value — no measurement host needed.
        //
        // Cancel any previously scheduled resize work so that rapid
        // resize events (live window drag) coalesce into a single
        // update after the last frame change settles.
        resizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let visible = self.tableView.rows(in: self.tableView.visibleRect)
            guard visible.length > 0 else { return }

            self.preCacheHeights(for: visible)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                self.tableView.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: visible.lowerBound ..< visible.upperBound)
                )
            }

            // Re-anchor to the bottom so the newest row stays above the
            // compose bar after row heights change.
            if wasNearBottom {
                self.scrollToBottom(animated: false)
            }
        }
        resizeWorkItem = work
        DispatchQueue.main.async(execute: work)
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
        guard row < rows.count else { return 44 }

        var targetWidth = tableView.tableColumns.first?.width ?? 0
        if targetWidth < 1 { targetWidth = scrollView.frame.width }
        if targetWidth < 1 { targetWidth = 600 }

        let messageRow = rows[row]
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
        let rowView = callbacks.makeRowView(messageRow, false)
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
