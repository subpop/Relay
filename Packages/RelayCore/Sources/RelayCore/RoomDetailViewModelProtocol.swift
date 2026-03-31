import Foundation

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

    /// Loads the room timeline, restoring cached messages and subscribing to live updates.
    func loadTimeline() async

    /// Paginates backward to load older messages from the room history.
    func loadMoreHistory() async

    /// Sends a text message to the room, optionally as a reply to another message.
    ///
    /// - Parameters:
    ///   - text: The message body (may contain Markdown).
    ///   - eventId: The event ID of the message being replied to, or `nil` for a new message.
    func send(text: String, inReplyTo eventId: String?) async

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
}
