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
    /// Shared configuration common to both renderers.
    let config: TimelineRendererConfig
    /// Shared callbacks common to both renderers.
    let callbacks: TimelineRendererCallbacks

    /// The consolidated timeline interaction callbacks.
    let actions: TimelineActions

    /// Called when a row appears on screen (for read receipt advancement).
    var onAppear: (MessageRow) -> Void

    /// Proxy that the parent uses to trigger scroll actions on the table.
    var scrollProxy: TimelineTableProxy

    func makeNSViewController(context: Context) -> TimelineTableViewController {
        let vc = TimelineTableViewController()
        vc.hasReachedEnd = config.hasReachedEnd
        vc.isLive = config.isLive
        configureCallbacks(vc, context: context)
        vc.updateRows(config.rows, typingIndicatorShown: config.typingIndicatorShown)
        scrollProxy.controller = vc
        return vc
    }

    func updateNSViewController(_ vc: TimelineTableViewController, context: Context) {
        vc.hasReachedEnd = config.hasReachedEnd
        vc.isLive = config.isLive
        configureCallbacks(vc, context: context)
        vc.updateRows(config.rows, typingIndicatorShown: config.typingIndicatorShown)
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

        let config = config
        vc.callbacks = .init(
            onNearBottomChanged: callbacks.onNearBottomChanged,
            onPaginateBackward: callbacks.onPaginateBackward,
            onPaginateForward: callbacks.onPaginateForward,
            onMessageAppeared: onAppear,
            onSwipeReply: { row in
                actions.reply(row.message)
            },
            makeRowView: { row, isNewlyAppended, swipeOffset, swipeIsLocked in
                TimelineRowView(
                    row: row,
                    isNewlyAppended: isNewlyAppended,
                    isHighlighted: config.highlightedMessageId == row.message.eventID,
                    isUnreadDivider: config.showUnreadMarker && row.message.id == config.firstUnreadMessageId,
                    showURLPreviews: config.showURLPreviews,
                    onAppear: onAppear,
                    swipeOffset: swipeOffset,
                    swipeIsLocked: swipeIsLocked,
                    injectedActions: actions
                )
            }
        )
    }
}
