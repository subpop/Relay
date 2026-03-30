import Foundation
import MatrixRustSDK
import os
import RelayCore

private let logger = Logger(subsystem: "RelaySDK", category: "Sync")

/// Manages the Matrix sync service lifecycle and state observation.
///
/// ``SyncManager`` encapsulates starting, stopping, and observing the SDK's `SyncService`.
/// It reports the current sync state and handles the initial sync wait. The caller
/// (``MatrixService``) uses this state to drive UI loading indicators and trigger
/// post-sync actions like room list loading.
@Observable
@MainActor
final class SyncManager {
    /// The current synchronization state.
    private(set) var syncState: SyncState = .idle

    /// The underlying SDK sync service, exposed so that sub-services (e.g. `RoomListManager`)
    /// can obtain their own service handles from it.
    private(set) var syncService: SyncService?
    private var syncTask: Task<Void, Never>?
    private var syncStateHandle: TaskHandle?

    /// Starts the sync service for the given client if not already running.
    ///
    /// This method builds the SDK's `SyncService`, observes its state transitions,
    /// and waits for the first successful sync before returning.
    ///
    /// - Parameter client: The authenticated Matrix SDK client.
    /// - Throws: If sync fails to start or is cancelled.
    func startSync(client: Client) async throws {
        guard syncState == .idle else { return }
        syncState = .syncing

        let builder = client.syncService()
        let service = try await builder.finish()
        try Task.checkCancellation()

        observeSyncState(service)

        await service.start()
        syncService = service
        try Task.checkCancellation()

        await waitForFirstSync()
    }

    /// Stops the sync service and resets state.
    func stop() async {
        syncStateHandle = nil
        if let syncService {
            await syncService.stop()
        }
        syncService = nil
        syncState = .idle
    }

    // MARK: - Private

    private func observeSyncState(_ service: SyncService) {
        let observer = SyncStateObserverProxy { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
        syncStateHandle = service.state(listener: observer)
    }

    private func waitForFirstSync() async {
        for _ in 0..<30 {
            if syncState == .running { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

// MARK: - Sync State Observer Bridge

/// Bridges `SyncServiceStateObserver` callbacks from the Matrix Rust SDK to a Swift closure.
nonisolated final class SyncStateObserverProxy: SyncServiceStateObserver, @unchecked Sendable {
    private let handler: @Sendable (SyncServiceState) -> Void

    init(handler: @escaping @Sendable (SyncServiceState) -> Void) {
        self.handler = handler
    }

    func onUpdate(state: SyncServiceState) {
        handler(state)
    }
}
