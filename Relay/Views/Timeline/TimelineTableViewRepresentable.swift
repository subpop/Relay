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

/// Bridges the `TimelineTableViewController` (AppKit) into the SwiftUI view
/// hierarchy. Passes row data and callbacks through a `Coordinator` so the
/// table view controller can create `TimelineRowView` instances with the
/// correct closures and trigger pagination / scroll events.
struct TimelineTableViewRepresentable: NSViewControllerRepresentable {
    let rows: [MessageRow]
    let hasReachedEnd: Bool
    let isLive: Bool

    // Row configuration values passed through to TimelineRowView.
    let showUnreadMarker: Bool
    let firstUnreadMessageId: String?
    let highlightedMessageId: String?
    let showURLPreviews: Bool

    /// The consolidated timeline interaction callbacks.
    let actions: TimelineActions

    /// Whether the typing indicator overlay is currently visible. Drives
    /// the extra bottom content inset on the table view.
    let typingIndicatorShown: Bool

    /// Called when a row appears on screen (for read receipt advancement).
    var onAppear: (MessageRow) -> Void

    // Renderer-level callbacks (not part of TimelineActions).
    var onNearBottomChanged: (Bool) -> Void
    var onPaginateBackward: () -> Void
    var onPaginateForward: () -> Void

    /// Proxy that the parent uses to trigger scroll actions on the table.
    var scrollProxy: TimelineTableProxy

    func makeNSViewController(context: Context) -> TimelineTableViewController {
        let vc = TimelineTableViewController()
        vc.hasReachedEnd = hasReachedEnd
        vc.isLive = isLive
        configureCallbacks(vc, context: context)
        vc.updateRows(rows, typingIndicatorShown: typingIndicatorShown)
        scrollProxy.controller = vc
        return vc
    }

    func updateNSViewController(_ vc: TimelineTableViewController, context: Context) {
        vc.hasReachedEnd = hasReachedEnd
        vc.isLive = isLive
        configureCallbacks(vc, context: context)
        vc.updateRows(rows, typingIndicatorShown: typingIndicatorShown)
        // Ensure the proxy always points to the current controller.
        scrollProxy.controller = vc
    }

    private func configureCallbacks(_ vc: TimelineTableViewController, context: Context) {
        let actions = actions

        // When a collapsed system-event group is expanded/collapsed, the row's
        // content height changes without a `rows` diff, so the table must be
        // told to re-measure that row (otherwise it stays clipped at the
        // cached collapsed height).
        actions.expandedGroups.onToggle = { [weak vc] groupID in
            vc?.remeasureRow(forMessageID: groupID)
        }

        // A link-preview card resizes to its image's aspect ratio once the
        // Open-Graph image loads; the row must re-measure so the height cache
        // picks up the new card height instead of the pre-load placeholder.
        actions.remeasureRow = { [weak vc] messageID in
            vc?.remeasureRow(forMessageID: messageID)
        }

        vc.callbacks = .init(
            onNearBottomChanged: onNearBottomChanged,
            onPaginateBackward: onPaginateBackward,
            onPaginateForward: onPaginateForward,
            onMessageAppeared: onAppear,
            onSwipeReply: { row in
                actions.reply(row.message)
            },
            makeRowView: { row, isNewlyAppended, swipeOffset, swipeIsLocked in
                TimelineRowView(
                    row: row,
                    isNewlyAppended: isNewlyAppended,
                    isHighlighted: highlightedMessageId == row.message.eventID,
                    isUnreadDivider: showUnreadMarker && row.message.id == firstUnreadMessageId,
                    showURLPreviews: showURLPreviews,
                    onAppear: onAppear,
                    swipeOffset: swipeOffset,
                    swipeIsLocked: swipeIsLocked,
                    injectedActions: actions
                )
            }
        )
    }
}
