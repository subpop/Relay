import MatrixKit
import MatrixKitSwiftData

typealias TimelinePayload = StoredTimelinePayload

/// Reads timeline windows independently of the room-list index rebuild actor.
actor TimelinePayloadReader {
    private let reader: MatrixStoreReader

    init(reader: MatrixStoreReader) {
        self.reader = reader
    }

    func timelinePayload(roomId: RoomId, limit: Int) -> TimelinePayload {
        (try? reader.timelinePayload(roomId, limit: limit)) ?? .empty
    }

    func timelinePayloadAround(
        roomId: RoomId,
        anchorEventId: String,
        olderLimit: Int,
        newerLimit: Int
    ) -> TimelinePayload? {
        try? reader.timelinePayloadAround(
            roomId,
            anchorEventId: EventId(unchecked: anchorEventId),
            olderLimit: olderLimit,
            newerLimit: newerLimit)
    }

    func markerSummary(roomId: RoomId) -> (
        firstUnreadEventId: String?, prevBatch: String?, historyGapEventId: String?
    ) {
        (try? reader.markerSummary(roomId)) ?? (nil, nil, nil)
    }
}
