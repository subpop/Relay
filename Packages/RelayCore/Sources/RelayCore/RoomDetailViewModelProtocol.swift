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
/// ``RoomDetailViewModelProtocol`` defines the observable state and actions needed by the
/// ``RoomDetailView`` to render messages, handle pagination, send messages and attachments,
/// and toggle reactions. Concrete implementations include ``RoomDetailViewModel`` (backed
/// by the Matrix Rust SDK) and ``PreviewRoomDetailViewModel`` (for SwiftUI previews).
@MainActor
public protocol RoomDetailViewModelProtocol: AnyObject, Observable {
    /// The ordered list of messages in the timeline, from oldest to newest.
    var messages: [TimelineMessage] { get }

    /// Whether the timeline is performing its initial load (before any messages are available).
    var isLoading: Bool { get }

    /// Whether older messages are currently being fetched via backward pagination.
    var isLoadingMore: Bool { get }

    /// Whether backward pagination has reached the beginning of the room's history.
    var hasReachedStart: Bool { get }

    /// The event ID of the first unread message, used to display the "New" divider.
    /// Cleared after the room is marked as read.
    var firstUnreadMessageId: String? { get set }

    /// Display names of users who are currently typing in this room.
    var typingUserDisplayNames: [String] { get }

    /// A user-facing error message from the most recent failed operation, if any.
    var errorMessage: String? { get set }

    /// Whether the timeline is showing live messages or focused on a specific event.
    var timelineFocus: TimelineFocusState { get }

    /// Loads the room timeline, restoring cached messages and subscribing to live updates.
    func loadTimeline() async

    /// Paginates backward to load older messages from the room history.
    func loadMoreHistory() async

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

    /// Redacts (deletes) a message from the room timeline.
    ///
    /// For local (unsent) messages the SDK attempts to cancel the send; for remote messages
    /// a redaction request is sent to the homeserver.
    ///
    /// - Parameters:
    ///   - messageId: The event or transaction ID of the message to redact.
    ///   - reason: An optional human-readable reason for the redaction.
    func redact(messageId: String, reason: String?) async
}
