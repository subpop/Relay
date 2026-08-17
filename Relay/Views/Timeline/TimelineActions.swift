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

/// Tracks which collapsed system event groups the user has expanded.
/// Separated into its own `@Observable` class so that ``CollapsedSystemEventsView``
/// can observe expansion state changes without making all of ``TimelineActions``
/// observable (which would invalidate every visible row on any mutation).
@Observable
final class ExpandedGroupsState {
    var expandedIDs: Set<String> = []

    /// Invoked after a group's expansion state changes, with the group's ID.
    /// The table-backed renderer (``TimelineTableViewController``) uses this to
    /// re-measure the affected row: expanding/collapsing changes the row's
    /// content height without changing the underlying message data, so the
    /// height cache would otherwise keep the stale (collapsed) value and clip
    /// the expanded content.
    @ObservationIgnored var onToggle: ((String) -> Void)?

    func isExpanded(_ groupID: String) -> Bool {
        expandedIDs.contains(groupID)
    }

    func toggle(_ groupID: String) {
        if expandedIDs.contains(groupID) {
            expandedIDs.remove(groupID)
        } else {
            expandedIDs.insert(groupID)
        }
        onToggle?(groupID)
    }
}

/// Consolidates timeline interaction callbacks into a single environment value,
/// eliminating prop-drilling of closures through ``TimelineRowView``,
/// ``MessageView``, ``MessageBubbleContent``, and ``ReplyPreviewBubble``.
///
/// Stored as a reference type so that SwiftUI's environment comparison uses
/// identity (`===`). As long as the same instance is injected, child views
/// are not invalidated when a parent re-evaluates its body.
///
/// Injected once at the renderer level (``TimelineTableViewRepresentable`` or
/// ``TimelineLazyVStackView``) and read by any descendant view that needs to
/// dispatch a user action.
final class TimelineActions: Equatable {
    nonisolated static func == (lhs: TimelineActions, rhs: TimelineActions) -> Bool {
        lhs === rhs
    }

    /// Toggles a reaction on a message. Parameters: (event ID, emoji key).
    var toggleReaction: (String, String) -> Void = { _, _ in }

    /// Scrolls to a replied-to message by event ID.
    var tapReply: (String) -> Void = { _ in }

    /// Initiates a reply to a message (e.g. swipe-to-reply).
    var reply: (TimelineMessage) -> Void = { _ in }

    /// Opens the user profile for the sender of a message (e.g. avatar double-tap).
    var avatarDoubleTap: (TimelineMessage) -> Void = { _ in }

    /// Opens the user profile for a user mention link click.
    var userTap: (String) -> Void = { _ in }

    /// Opens a room from a room link click.
    var roomTap: ((String) -> Void)?

    /// Dispatches a context menu action (reply, copy, pin, edit, delete).
    var contextAction: (TimelineRowContextAction) -> Void = { _ in }

    /// Presents the reaction picker overlay for a message. Parameters:
    /// (event ID, bubble frame in **global** coordinates, isOutgoing).
    ///
    /// Global coordinates are used so the frame survives crossing the table
    /// renderer's per-row `NSHostingView` boundary (a named timeline coordinate
    /// space can't resolve inside a cell); the overlay converts to its local
    /// space.
    var presentReactionPicker: (String, CGRect, Bool) -> Void = { _, _, _ in }

    /// Streams a message's latest global bubble frame. While that message's
    /// reaction picker is open, the timeline uses it to keep the picker
    /// anchored to the bubble as the layout changes (e.g. a window resize).
    /// Parameters: (event ID, bubble frame in global coordinates).
    var updateReactionPickerFrame: (String, CGRect) -> Void = { _, _ in }

    /// Dismisses the highlight animation on the currently highlighted message.
    var highlightDismissed: () -> Void = {}

    /// The current user's room-level permissions, used by context menus and
    /// the compose bar to gate actions on power level capabilities.
    var permissions: RoomPermissions?

    /// The Matrix user ID of the signed-in user. Used to determine whether
    /// replied-to messages are outgoing.
    var currentUserID: String?

    /// Observable state tracking which collapsed system event groups the user
    /// has expanded. Keyed by the first message's ID in each collapsed group.
    let expandedGroups = ExpandedGroupsState()

    /// Requests that the table-backed renderer re-measure a specific row by
    /// message ID. Used when a row's content height changes asynchronously
    /// without any change to the underlying message data — e.g. a link-preview
    /// card resizing to its image's aspect ratio once the Open-Graph image
    /// loads. Without this, the height cache keeps the pre-load placeholder
    /// height and clips (or leaves a gap under) the resized card.
    var remeasureRow: ((String) -> Void)?

    /// Creates a ``TimelineActions`` with default (no-op) callbacks.
    init(currentUserID: String? = nil) {
        self.currentUserID = currentUserID
    }

    /// Binds all interaction callbacks for a ``TimelineView``.
    ///
    /// Called once from `.task` to capture `@State` / `@Environment` references
    /// that remain valid for the view's lifetime. Because the instance identity
    /// is stable, re-injecting it into the environment does not invalidate
    /// child views.
    func configure(
        viewModel: any TimelineStateProviding,
        compose: ComposeViewModel,
        roomPermissions: RoomPermissions?,
        currentUserID: String?,
        onUserTap: ((UserProfile) -> Void)?,
        onRoomTap: ((String) -> Void)?,
        scrollToRow: @escaping (String) -> Void,
        setHighlightedMessage: @escaping (String?) -> Void,
        setFocusedMessage: @escaping (String?) -> Void,
        handleContextAction: @escaping (TimelineRowContextAction) -> Void,
        presentReactionPicker: @escaping (String, CGRect, Bool) -> Void,
        updateReactionPickerFrame: @escaping (String, CGRect) -> Void,
        members: [RoomMemberDetails]
    ) {
        self.toggleReaction = { messageId, key in
            guard let actionsVM = viewModel as? any TimelineActionsProviding else { return }
            Task { await actionsVM.toggleReaction(messageId: messageId, key: key) }
        }
        self.tapReply = { eventID in
            if let message = viewModel.messages.first(where: { $0.eventID == eventID }) {
                scrollToRow(message.id)
                setHighlightedMessage(eventID)
            } else {
                setFocusedMessage(eventID)
            }
        }
        self.reply = { message in
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                compose.replyingTo = message
            }
            compose.shouldFocusTextField = true
        }
        self.avatarDoubleTap = { message in
            onUserTap?(UserProfile(message: message))
        }
        self.userTap = { userId in
            let member = members.first(where: { $0.userId == userId })
            let profile = member.map { UserProfile(member: $0) }
                ?? UserProfile(userId: userId)
            onUserTap?(profile)
        }
        self.roomTap = onRoomTap
        self.contextAction = handleContextAction
        self.presentReactionPicker = presentReactionPicker
        self.updateReactionPickerFrame = updateReactionPickerFrame
        self.highlightDismissed = {
            setHighlightedMessage(nil)
        }
        self.permissions = roomPermissions
        self.currentUserID = currentUserID
    }
}

// MARK: - Environment Key

private struct TimelineActionsKey: EnvironmentKey {
    @MainActor static let defaultValue = TimelineActions()
}

extension EnvironmentValues {
    /// The timeline interaction callbacks available to all descendant views.
    var timelineActions: TimelineActions {
        get { self[TimelineActionsKey.self] }
        set { self[TimelineActionsKey.self] = newValue }
    }
}
