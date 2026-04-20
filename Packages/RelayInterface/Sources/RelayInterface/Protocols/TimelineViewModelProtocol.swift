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

import Foundation

/// Describes whether the timeline is showing live messages or focused on a specific event.
public enum TimelineFocusState: Equatable, Sendable {
    /// The timeline is showing the latest (live) messages, anchored at the bottom.
    case live
    /// The timeline is focused on a specific event with context around it.
    case focusedOnEvent(String)
}

/// The view model protocol for displaying and interacting with a room's message timeline.
///
/// ``TimelineViewModelProtocol`` defines the observable state and actions needed by the
/// ``TimelineView`` to render messages, handle pagination, send messages and attachments,
/// and toggle reactions. Concrete implementations include ``TimelineViewModel`` (backed
/// by the Matrix Rust SDK) and ``PreviewTimelineViewModel`` (for SwiftUI previews).
@MainActor
public protocol TimelineViewModelProtocol: AnyObject, Observable {
    /// The ordered list of messages in the timeline, from oldest to newest.
    var messages: [TimelineMessage] { get }

    /// A monotonically increasing counter that is bumped each time ``messages``
    /// is replaced with a new value. Use this in `onChange` modifiers instead
    /// of comparing the full array, which avoids an O(n) equality check on
    /// every SwiftUI body evaluation.
    var messagesVersion: UInt { get }

    /// Whether the timeline is performing its initial load (before any messages are available).
    var isLoading: Bool { get }

    /// Whether older messages are currently being fetched via backward pagination.
    var isLoadingMore: Bool { get }

    /// Whether backward pagination has reached the beginning of the room's history.
    var hasReachedStart: Bool { get }

    /// Whether forward pagination has reached the live edge of the timeline.
    ///
    /// Only meaningful when the timeline is focused on a specific event. When `true`,
    /// all newer messages have been loaded and the timeline can transition to live mode.
    var hasReachedEnd: Bool { get }

    /// The event ID of the first unread message, used to display the "New" divider.
    /// Cleared after the room is marked as read.
    var firstUnreadMessageId: String? { get set }

    /// Display names of users who are currently typing in this room.
    var typingUserDisplayNames: [String] { get }

    /// Whether the timeline is showing live messages or focused on a specific event.
    var timelineFocus: TimelineFocusState { get }

    /// Loads the room timeline, restoring cached messages and subscribing to live updates.
    ///
    /// - Parameter fullyReadEventId: If provided, the timeline is loaded focused on this event
    ///   instead of the live edge, allowing the user to catch up from their last read position.
    func loadTimeline(focusedOnEventId fullyReadEventId: String?) async

    /// Paginates backward to load older messages from the room history.
    func loadMoreHistory() async

    /// Paginates forward to load newer messages toward the live edge.
    ///
    /// Only meaningful when the timeline is focused on a specific event. When forward
    /// pagination reaches the live edge, ``hasReachedEnd`` becomes `true`.
    func loadMoreFuture() async

    /// Focuses the timeline on a specific event, loading context events around it.
    ///
    /// Creates a new event-focused timeline centered on the given event ID. The previous
    /// live timeline is torn down and replaced. Call ``returnToLive()`` to restore the
    /// live timeline.
    ///
    /// - Parameter eventId: The Matrix event ID to focus on.
    func focusOnEvent(eventId: String) async

    /// Returns the timeline to its live state after an event-focused navigation.
    ///
    /// Tears down the event-focused timeline and recreates the standard live timeline
    /// anchored at the most recent messages.
    func returnToLive() async

    /// Advances the fully-read marker to the specified event ID.
    ///
    /// Sends a `m.fully_read` receipt to the server so the read position is synced
    /// across devices. The marker is only advanced forward, never backward.
    ///
    /// - Parameter eventId: The event ID to mark as the furthest-read position.
    func sendFullyReadReceipt(upTo eventId: String) async

    /// Sends a text message to the room, optionally as a reply to another message.
    ///
    /// - Parameters:
    ///   - text: The message body (may contain Markdown and Matrix.to mention links).
    ///   - eventId: The event ID of the message being replied to, or `nil` for a new message.
    ///   - mentionedUserIds: Matrix user IDs mentioned in the message, included in the
    ///     `m.mentions` event content for notification routing. Defaults to an empty array.
    func send(text: String, inReplyTo eventId: String?, mentionedUserIds: [String]) async

    /// Sends a file attachment to the room.
    ///
    /// The file type is automatically detected. Images include a blurhash placeholder;
    /// videos and generic files are sent with appropriate metadata.
    ///
    /// - Parameters:
    ///   - url: A local file URL pointing to the attachment to upload.
    ///   - caption: Optional alt-text / caption to include with the attachment.
    func sendAttachment(url: URL, caption: String?) async

    /// Toggles an emoji reaction on a message. Adds the reaction if not present; removes it if already sent.
    ///
    /// - Parameters:
    ///   - messageId: The event or transaction ID of the message to react to.
    ///   - key: The emoji character to toggle (e.g. `"👍"`).
    func toggleReaction(messageId: String, key: String) async

    /// Edits the text content of a previously sent message.
    ///
    /// Only text messages sent by the current user can be edited. The edit replaces
    /// the message body and formatted body with the new content.
    ///
    /// - Parameters:
    ///   - messageId: The event or transaction ID of the message to edit.
    ///   - newText: The replacement message body (may contain Markdown and Matrix.to mention links).
    ///   - mentionedUserIds: Matrix user IDs mentioned in the new text.
    func edit(messageId: String, newText: String, mentionedUserIds: [String]) async

    /// Redacts (deletes) a message from the room timeline.
    ///
    /// For local (unsent) messages the SDK attempts to cancel the send; for remote messages
    /// a redaction request is sent to the homeserver.
    ///
    /// - Parameters:
    ///   - messageId: The event or transaction ID of the message to redact.
    ///   - reason: An optional human-readable reason for the redaction.
    func redact(messageId: String, reason: String?) async

    /// Pins a message in the room.
    ///
    /// Sends a state event to the homeserver to add the given event to the room's
    /// pinned events list. Requires sufficient power level in the room.
    ///
    /// - Parameter eventId: The Matrix event ID of the message to pin.
    func pin(eventId: String) async

    /// Unpins a message from the room.
    ///
    /// Sends a state event to the homeserver to remove the given event from the room's
    /// pinned events list.
    ///
    /// - Parameter eventId: The Matrix event ID of the message to unpin.
    func unpin(eventId: String) async
}
