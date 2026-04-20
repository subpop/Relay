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
///
/// ## Offline Handling
///
/// ``SyncManager`` integrates with ``NetworkMonitor`` to handle connectivity changes:
///
/// - When the network becomes unavailable, the sync service is stopped and
///   ``syncState`` transitions to `.offline`. Cached data remains accessible.
/// - When connectivity is restored, the sync service is rebuilt with offline mode
///   and shared position enabled, allowing the SDK to resume from its last sync
///   position and deliver incremental diffs rather than full state replacements.
/// - The ``onSyncServiceRestarted`` callback notifies ``MatrixService`` so it can
///   re-wire sub-services (e.g. ``RoomListManager``) to the new sync service.
@Observable
@MainActor
final class SyncManager {
    /// The current synchronization state.
    private(set) var syncState: SyncState = .idle

    /// The underlying SDK sync service, exposed so that sub-services (e.g. `RoomListManager`)
    /// can obtain their own service handles from it.
    private(set) var syncService: SyncService?

    /// Called when the sync service is rebuilt after a connectivity restoration.
    ///
    /// ``MatrixService`` sets this to re-wire ``RoomListManager`` to the new
    /// sync service without tearing down existing room state.
    var onSyncServiceRestarted: ((SyncService) async throws -> Void)?

    private let networkMonitor: NetworkMonitor

    private var client: (any ClientProxyProtocol)?
    private var syncStateHandle: TaskHandle?
    private var stateObservationTask: Task<Void, Never>?
    private var networkObservationTask: Task<Void, Never>?

    /// Whether the sync service has completed its initial startup.
    /// Used to distinguish the first `startSync` call from network-triggered restarts.
    private var hasCompletedInitialSync = false

    init(networkMonitor: NetworkMonitor) {
        self.networkMonitor = networkMonitor
    }

    /// Starts the sync service for the given client if not already running.
    ///
    /// This method builds the SDK's `SyncService`, observes its state transitions
    /// via `SDKListener`, and waits for the first `.running` state before returning.
    /// It also begins monitoring network connectivity to automatically stop and
    /// restart the sync service as needed.
    ///
    /// - Parameter client: The authenticated client proxy.
    /// - Throws: If sync fails to start or is cancelled.
    func startSync(client: any ClientProxyProtocol) async throws {
        guard syncState == .idle else { return }

        self.client = client
        syncState = .syncing

        try await buildAndStartSyncService(client: client)
        try Task.checkCancellation()

        // Wait for the first .running state (up to 15 seconds)
        await waitForFirstSync()
        hasCompletedInitialSync = true

        // Begin observing network changes for offline/online transitions
        startNetworkObservation()
    }

    /// Stops the sync service, network monitoring, and resets all state.
    ///
    /// Called during logout to fully tear down the sync layer.
    func stop() async {
        networkObservationTask?.cancel()
        networkObservationTask = nil
        stateObservationTask?.cancel()
        stateObservationTask = nil
        syncStateHandle = nil

        if let syncService {
            await syncService.stop()
        }
        syncService = nil
        client = nil
        hasCompletedInitialSync = false
        onSyncServiceRestarted = nil
        syncState = .idle
    }

    // MARK: - Private

    /// Builds the SDK `SyncService`, subscribes to its state, and starts it.
    ///
    /// - Parameters:
    ///   - client: The authenticated client proxy.
    ///   - offlineMode: Whether to enable offline mode (used on restarts to
    ///     initialize from local cache before syncing with the server).
    private func buildAndStartSyncService(
        client: any ClientProxyProtocol,
        offlineMode: Bool = false
    ) async throws {
        var builder = client.syncService()
        if offlineMode {
            builder = builder.withOfflineMode()
        }
        let service = try await builder.finish()
        try Task.checkCancellation()

        observeSyncServiceState(service)

        await service.start()
        syncService = service
    }

    /// Subscribes to the SDK sync service's state stream and maps transitions
    /// to the app-level ``SyncState``.
    private func observeSyncServiceState(_ service: SyncService) {
        // Cancel any previous observation before starting a new one.
        stateObservationTask?.cancel()
        syncStateHandle = nil

        let (stream, continuation) = AsyncStream<SyncServiceState>.makeStream()
        let listener = SDKListener<SyncServiceState> { state in
            continuation.yield(state)
        }
        syncStateHandle = service.state(listener: listener)

        stateObservationTask = Task { [weak self] in
            for await state in stream {
                guard let self else { break }
                switch state {
                case .running:
                    self.syncState = .running
                case .idle:
                    break
                case .offline:
                    // The SDK itself detected an offline condition. Treat this
                    // the same as a network monitor offline transition.
                    self.syncState = .offline
                case .terminated:
                    self.syncState = .error("The sync service was terminated.")
                case .error:
                    self.syncState = .error("The sync service encountered an error.")
                }
            }
        }
    }

    /// Observes ``NetworkMonitor/isConnected`` and stops or restarts the sync
    /// service when connectivity changes.
    private func startNetworkObservation() {
        networkObservationTask?.cancel()
        networkObservationTask = Task { [weak self] in
            guard let self else { return }

            // Use withObservationTracking to react to isConnected changes.
            while !Task.isCancelled {
                let isConnected = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.networkMonitor.isConnected
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume(returning: self.networkMonitor.isConnected)
                        }
                    }
                }

                guard !Task.isCancelled else { return }

                if !isConnected {
                    await self.handleOffline()
                } else if self.syncState == .offline {
                    await self.handleOnline()
                }
            }
        }
    }

    /// Stops the sync service and disables send queues when the network becomes
    /// unavailable.
    ///
    /// Disabling send queues prevents the SDK from attempting to deliver queued
    /// messages while there is no network path. Queued messages remain in the
    /// local store and are flushed when ``handleOnline()`` re-enables them.
    private func handleOffline() async {
        guard syncState == .running || syncState == .syncing else { return }

        logger.info("Network lost — stopping sync service")

        // Disable send queues so the SDK stops trying to deliver messages
        await client?.enableAllSendQueues(enable: false)

        stateObservationTask?.cancel()
        stateObservationTask = nil
        syncStateHandle = nil

        if let syncService {
            await syncService.stop()
        }
        syncService = nil
        syncState = .offline
    }

    /// Rebuilds and restarts the sync service when connectivity is restored.
    ///
    /// Uses offline mode so the SDK initializes from local cache first, and
    /// shared position so it resumes from the last sync position. The SDK
    /// delivers incremental diffs to reconcile state rather than full replacements.
    ///
    /// Re-enables send queues after the sync service reaches `.running`, which
    /// flushes any messages that were queued while offline.
    private func handleOnline() async {
        guard let client, syncState == .offline else { return }

        logger.info("Network restored — restarting sync service")
        syncState = .syncing

        do {
            try await buildAndStartSyncService(client: client, offlineMode: true)
            try Task.checkCancellation()

            // Wait for the sync to reach .running before notifying sub-services
            await waitForFirstSync()

            // Re-enable send queues so any messages queued while offline are
            // flushed to the server now that we have connectivity.
            await client.enableAllSendQueues(enable: true)

            // Notify MatrixService to re-wire sub-services to the new SyncService
            if let syncService {
                try await onSyncServiceRestarted?(syncService)
            }
        } catch is CancellationError {
            // Shutdown in progress — don't overwrite state
        } catch {
            logger.error("Failed to restart sync after connectivity restored: \(error)")
            syncState = .error("Failed to restart sync: \(error.localizedDescription)")
        }
    }

    private func waitForFirstSync() async {
        for _ in 0..<30 {
            if syncState == .running { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
