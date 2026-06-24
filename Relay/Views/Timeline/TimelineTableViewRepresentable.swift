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

    /// The view model, used to observe typing state for the synthetic
    /// typing indicator row without invalidating the parent view's body.
    let viewModel: any TimelineViewModelProtocol

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
        vc.updateRows(rows, typingUsers: viewModel.typingUsers)
        scrollProxy.controller = vc
        return vc
    }

    func updateNSViewController(_ vc: TimelineTableViewController, context: Context) {
        vc.hasReachedEnd = hasReachedEnd
        vc.isLive = isLive
        configureCallbacks(vc, context: context)
        vc.updateRows(rows, typingUsers: viewModel.typingUsers)
        // Ensure the proxy always points to the current controller.
        scrollProxy.controller = vc
    }

    private func configureCallbacks(_ vc: TimelineTableViewController, context: Context) {
        let actions = actions
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
                    canTranslateProvider: { viewModel.canTranslateMessage($0) },
                    translationsVersion: viewModel.translationsVersion,
                    swipeOffset: swipeOffset,
                    swipeIsLocked: swipeIsLocked,
                    injectedActions: actions
                )
            }
        )
    }
}
