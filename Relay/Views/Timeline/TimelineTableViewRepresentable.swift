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
    let currentUserID: String?

    // Callbacks
    var onToggleReaction: (String, String) -> Void
    var onTapReply: (String) -> Void
    var onReply: (TimelineMessage) -> Void
    var onAvatarDoubleTap: (TimelineMessage) -> Void
    var onUserTap: (String) -> Void
    var onRoomTap: ((String) -> Void)?
    var onAppear: (MessageRow) -> Void
    var onContextAction: (TimelineRowContextAction) -> Void
    var onHighlightDismissed: () -> Void
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
        vc.updateRows(rows)
        scrollProxy.controller = vc
        return vc
    }

    func updateNSViewController(_ vc: TimelineTableViewController, context: Context) {
        vc.hasReachedEnd = hasReachedEnd
        vc.isLive = isLive
        configureCallbacks(vc, context: context)
        vc.updateRows(rows)
        // Ensure the proxy always points to the current controller.
        scrollProxy.controller = vc
    }

    private func configureCallbacks(_ vc: TimelineTableViewController, context: Context) {
        let swipeState = vc.swipeState
        vc.callbacks = .init(
            onNearBottomChanged: onNearBottomChanged,
            onPaginateBackward: onPaginateBackward,
            onPaginateForward: onPaginateForward,
            onMessageAppeared: onAppear,
            onSwipeReply: { row in
                onReply(row.message)
            },
            makeRowView: { row, isNewlyAppended in
                TimelineRowView(
                    row: row,
                    isNewlyAppended: isNewlyAppended,
                    showUnreadMarker: showUnreadMarker,
                    firstUnreadMessageId: firstUnreadMessageId,
                    highlightedMessageId: highlightedMessageId,
                    showURLPreviews: showURLPreviews,
                    currentUserID: currentUserID,
                    onToggleReaction: onToggleReaction,
                    onTapReply: onTapReply,
                    onReply: onReply,
                    onAvatarDoubleTap: onAvatarDoubleTap,
                    onUserTap: onUserTap,
                    onRoomTap: onRoomTap,
                    onAppear: onAppear,
                    onContextAction: onContextAction,
                    onHighlightDismissed: onHighlightDismissed,
                    swipeState: swipeState
                )
            }
        )
    }
}
