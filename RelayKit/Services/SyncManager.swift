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

private let logger = Logger(subsystem: "RelayKit", category: "Sync")

/// Manages the Matrix sync service lifecycle and state observation.
///
/// ``SyncManager`` encapsulates starting, stopping, and observing the SDK's `SyncService`.
/// It reports the current sync state using an `SDKListener` for reactive state updates.
/// The caller (``MatrixService``) uses this state to drive UI loading indicators and
/// trigger post-sync actions like room list loading.
@Observable
@MainActor
final class SyncManager {
    /// The current synchronization state.
    private(set) var syncState: SyncState = .idle

    /// The underlying SDK sync service, exposed so that sub-services (e.g. `RoomListManager`)
    /// can obtain their own service handles from it.
    private(set) var syncService: SyncService?

    private var syncStateHandle: TaskHandle?
    private var stateObservationTask: Task<Void, Never>?

    /// Starts the sync service for the given client if not already running.
    ///
    /// This method builds the SDK's `SyncService`, observes its state transitions
    /// via `SDKListener`, and waits for the first `.running` state before returning.
    ///
    /// - Parameter client: The authenticated client proxy.
    /// - Throws: If sync fails to start or is cancelled.
    func startSync(client: any ClientProxyProtocol) async throws {
        guard syncState == .idle else { return }
        syncState = .syncing

        let builder = client.syncService()
        let service = try await builder.finish()
        try Task.checkCancellation()

        let (stream, continuation) = AsyncStream<SyncServiceState>.makeStream()
        let listener = SDKListener<SyncServiceState> { state in
            continuation.yield(state)
        }
        syncStateHandle = service.state(listener: listener)

        // Observe state changes reactively
        stateObservationTask = Task { [weak self] in
            for await state in stream {
                guard let self else { break }
                switch state {
                case .running:
                    self.syncState = .running
                case .idle, .offline:
                    break
                case .terminated, .error:
                    self.syncState = .error
                }
            }
        }

        await service.start()
        syncService = service
        try Task.checkCancellation()

        // Wait for the first .running state (up to 15 seconds)
        await waitForFirstSync()
    }

    /// Stops the sync service and resets state.
    func stop() async {
        stateObservationTask?.cancel()
        stateObservationTask = nil
        syncStateHandle = nil
        if let syncService {
            await syncService.stop()
        }
        syncService = nil
        syncState = .idle
    }

    // MARK: - Private

    private func waitForFirstSync() async {
        for _ in 0..<30 {
            if syncState == .running { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
