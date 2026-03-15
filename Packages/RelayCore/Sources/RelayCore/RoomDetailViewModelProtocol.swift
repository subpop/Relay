import Foundation

@MainActor
public protocol RoomDetailViewModelProtocol: AnyObject, Observable {
    var messages: [TimelineMessage] { get }
    var isLoading: Bool { get }
    var isLoadingMore: Bool { get }
    var hasReachedStart: Bool { get }
    var firstUnreadMessageId: String? { get }

    func loadTimeline() async
    func loadMoreHistory() async
    func send(text: String) async
    func sendAttachment(url: URL) async
}
