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
import RelayInterface
import os

/// Manages backward and forward pagination for a room timeline.
///
/// ``TimelinePaginator`` subscribes to the SDK's back-pagination status stream
/// and drives the auto-pagination loop that ensures the viewport has enough
/// message-like items. It reports state changes (loading, reached-start,
/// reached-end) back to the owning ``TimelineViewModel`` via callbacks.
final class TimelinePaginator {

    /// Maximum number of retry attempts for auto-pagination when the server
    /// is unreachable. Each attempt uses exponential backoff (1s, 2s, 4s).
    private static let maxPaginationRetries = 3

    /// Set to `true` when backward pagination hits a permanent error (e.g.
    /// corrupted event cache). Prevents the auto-pagination loop from
    /// retrying indefinitely.
    private(set) var paginationPermanentlyFailed = false

    private var paginationTask: Task<Void, Never>?
    @ObservationIgnored private var paginationHandle: TaskHandle?

    private let roomLabel: String
    private let roomId: String
    private weak var activityLog: ActivityLog?

    /// Called when ``isLoadingMore`` changes.
    var onLoadingMoreChanged: ((Bool) -> Void)?
    /// Called when ``hasReachedStart`` changes.
    var onHasReachedStartChanged: ((Bool) -> Void)?
    /// Called when the initial auto-pagination loop has settled and loading
    /// can be cleared.
    var onInitialLoadSettled: (() async -> Void)?
    /// Returns the current number of message-like items, used to decide
    /// whether more auto-pagination is needed.
    var msgLikeItemCount: (() -> Int)?

    init(roomLabel: String, roomId: String, activityLog: ActivityLog?) {
        self.roomLabel = roomLabel
        self.roomId = roomId
        self.activityLog = activityLog
    }

    // MARK: - Observation

    /// Subscribes to the back-pagination status of the given timeline and
    /// begins the auto-pagination loop.
    // swiftlint:disable:next identifier_name
    func observePaginationStatus(_ tl: Timeline) async throws {
        let (stream, continuation) = AsyncStream<PaginationStatus>.makeStream()
        let listener = SDKListener<PaginationStatus> { status in
            continuation.yield(status)
        }
        paginationHandle = try await tl.subscribeToBackPaginationStatus(listener: listener)

        paginationTask = Task { [weak self] in
            for await status in stream {
                guard let self else { break }

                switch status {
                case .idle(let hitStart):
                    self.onLoadingMoreChanged?(false)
                    self.onHasReachedStartChanged?(hitStart)
                    self.activityLog?.log(
                        category: .timeline, severity: .debug, source: "TimelinePaginator",
                        summary: "Pagination idle in \(self.roomLabel) (hitStart: \(hitStart))",
                        roomId: self.roomId
                    )

                    // Auto-paginate if we have few message-like events and
                    // haven't hit start, ensuring enough content to fill the
                    // viewport.
                    let msgLikeCount = self.msgLikeItemCount?() ?? 0
                    if !hitStart && msgLikeCount < 20 && !self.paginationPermanentlyFailed {
                        let autoPaginateState = PerformanceSignposts.roomSwitch.beginInterval(
                            PerformanceSignposts.RoomSwitchName.autoPaginate,
                            "\(self.roomLabel) (\(msgLikeCount) msgs, need 20)"
                        )
                        let needed = UInt16(max(20 - msgLikeCount, 5))
                        let succeeded = await self.paginateBackwardsWithRetry(tl, numEvents: needed)
                        if !succeeded {
                            self.paginationPermanentlyFailed = true
                        }
                        PerformanceSignposts.roomSwitch.endInterval(
                            PerformanceSignposts.RoomSwitchName.autoPaginate,
                            autoPaginateState,
                            "needed \(needed), succeeded: \(succeeded)"
                        )
                    }
                    if hitStart || (self.msgLikeItemCount?() ?? 0) >= 20
                        || self.paginationPermanentlyFailed {
                        await self.onInitialLoadSettled?()
                    }
                case .paginating:
                    self.onLoadingMoreChanged?(true)
                    self.activityLog?.log(
                        category: .timeline, severity: .debug, source: "TimelinePaginator",
                        summary: "Paginating backwards in \(self.roomLabel)",
                        roomId: self.roomId
                    )
                }
            }
        }
    }

    // MARK: - Manual Pagination

    /// Paginates backward to load older messages.
    func loadMoreHistory(_ timeline: Timeline, isLoadingMore: Bool, hasReachedStart: Bool) async {
        guard !isLoadingMore, !hasReachedStart else { return }
        do {
            _ = try await timeline.paginateBackwards(numEvents: 100)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelinePaginator",
                summary: "Failed to load earlier messages in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
        }
    }

    /// Paginates forward to load newer messages toward the live edge.
    ///
    /// - Returns: `true` if forward pagination reached the live edge.
    @discardableResult
    func loadMoreFuture(_ timeline: Timeline, hasReachedEnd: Bool) async -> Bool {
        guard !hasReachedEnd else { return true }
        do {
            return try await timeline.paginateForwards(numEvents: 40)
        } catch {
            activityLog?.log(
                category: .timeline, severity: .error, source: "TimelinePaginator",
                summary: "Failed to load newer messages in \(roomLabel)",
                detail: error.localizedDescription, roomId: roomId
            )
            return false
        }
    }

    // MARK: - Retry Logic

    /// Attempts backward pagination with retry and exponential backoff.
    ///
    /// On transient errors (network unreachable, connection timeout), retries
    /// up to ``maxPaginationRetries`` times with 1s / 2s / 4s delays. On
    /// success or permanent failure, returns without throwing.
    ///
    /// - Returns: `true` if pagination succeeded, `false` if it failed
    ///   permanently (non-transient error or retries exhausted).
    @discardableResult
    private func paginateBackwardsWithRetry(_ timeline: Timeline, numEvents: UInt16 = 100) async -> Bool {
        for attempt in 0 ..< Self.maxPaginationRetries {
            do {
                if attempt > 0 {
                    try await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return false }
                }
                _ = try await timeline.paginateBackwards(numEvents: numEvents)
                return true
            } catch is CancellationError {
                return false
            } catch {
                let isTransient = NetworkErrorClassifier.isOfflineShaped(error)
                    || "\(error)".contains("HostUnreachable")
                if isTransient && attempt < Self.maxPaginationRetries - 1 {
                    let delay = Duration.seconds(1 << attempt) // 1s, 2s, 4s
                    activityLog?.log(
                        category: .timeline, severity: .warning, source: "TimelinePaginator",
                        summary: "Pagination attempt \(attempt + 1) failed (transient) in \(roomLabel), retrying in \(1 << attempt)s",
                        detail: error.localizedDescription, roomId: roomId
                    )
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return false }
                } else {
                    activityLog?.log(
                        category: .timeline, severity: .error, source: "TimelinePaginator",
                        summary: "Pagination failed in \(roomLabel)",
                        detail: "\(error)",
                        roomId: roomId
                    )
                    return false
                }
            }
        }
        return false
    }

    // MARK: - Teardown

    /// Cancels the pagination observation task and releases SDK handles.
    func teardown() {
        paginationTask?.cancel()
        paginationTask = nil
        paginationHandle = nil
        paginationPermanentlyFailed = false
    }
}
