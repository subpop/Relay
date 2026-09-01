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

import AppKit
import Foundation
import RelayInterface
/// Manages the Matrix sync service lifecycle using a unified state machine.
///
/// ``SyncManager`` encapsulates starting, stopping, and observing the SDK's
/// `SyncService`. It reports the current sync state using ``syncState`` for
/// reactive UI updates, and notifies ``MatrixService`` via callbacks when the
/// sync service is rebuilt.
///
/// ## Unified Event Loop
///
/// All external signals — network connectivity changes, macOS sleep/wake
/// notifications, SDK sync state transitions, and reconnect timer firings —
/// are funnelled into a single ``ConnectivityInput`` stream and processed
/// sequentially by a `for await` loop. This eliminates races between
/// independent observation loops and makes the internal lifecycle phase
/// explicit via ``LifecyclePhase``.
///
/// ## Offline Handling
///
/// When the network becomes unavailable (debounced by ``NetworkMonitor``),
/// the sync service is stopped and ``syncState`` transitions to `.offline`.
/// Cached data remains accessible. When connectivity is restored, the sync
/// service is rebuilt with offline mode and shared position enabled, allowing
/// the SDK to resume from its last sync position.
///
/// ## Sleep / Wake
///
/// On macOS, `NWPathMonitor` often does not report a path change across a
/// sleep/wake cycle when WiFi stays associated. ``SyncManager`` observes
/// `NSWorkspace.willSleepNotification` and `didWakeNotification` to
/// proactively stop and restart the sync service. The sleep handler tears
/// down sync internals **without** publishing `.offline` so the banner
/// doesn't flash during routine sleep/wake cycles.
@Observable
@MainActor
final class SyncManager {
    // MARK: - Nested Types

    /// External events that can affect whether the sync service should be
    /// running. All events are funnelled into a single ``AsyncStream`` and
    /// processed sequentially.
    private enum ConnectivityInput: CustomStringConvertible {
        case networkOnline
        case networkOffline
        case systemWillSleep
        case systemDidWake
        case sdkState(SyncServiceState)
        case reconnectTimerFired

        var description: String {
            switch self {
            case .networkOnline: "networkOnline"
            case .networkOffline: "networkOffline"
            case .systemWillSleep: "systemWillSleep"
            case .systemDidWake: "systemDidWake"
            case .sdkState(let s): "sdkState(\(s))"
            case .reconnectTimerFired: "reconnectTimerFired"
            }
        }
    }

    /// The internal lifecycle phase of the sync service. Replaces the
    /// previous `isRebuilding`, `isPendingOnlineRestore`, and
    /// `hasCompletedInitialSync` boolean flags with an explicit enum that
    /// makes invalid state combinations unrepresentable.
    private enum LifecyclePhase: CustomStringConvertible {
        /// No sync service has been started yet.
        case idle
        /// Sync service is running normally.
        case active
        /// System is asleep. Sync service has been torn down but
        /// ``syncState`` was not published as `.offline` to avoid
        /// a visible banner flash.
        case sleeping
        /// Network is unavailable or homeserver is unreachable. Sync
        /// service is stopped. Published state is `.offline`.
        case offline
        /// Actively rebuilding the sync service (post-wake or
        /// post-reconnect). SDK `.error`/`.offline` states are
        /// suppressed during this phase.
        case rebuilding
        /// Session was restored from cache but we haven't successfully
        /// connected to the homeserver yet. The network observer calls
        /// ``onPendingOnlineRestore`` instead of rebuilding sync.
        case pendingRestore

        var description: String {
            switch self {
            case .idle: "idle"
            case .active: "active"
            case .sleeping: "sleeping"
            case .offline: "offline"
            case .rebuilding: "rebuilding"
            case .pendingRestore: "pendingRestore"
            }
        }
    }

    // MARK: - Public Properties

    /// The current synchronization state.
    ///
    /// The setter deduplicates identical assignments so that `@Observable`
    /// does not fire spurious change notifications — `@Observable` does not
    /// perform equality checks on its own, so without this guard every SDK
    /// state emission (even repeated `.running`) would invalidate the
    /// entire view tree.
    @ObservationIgnored private var _syncState: SyncState = .idle
    private(set) var syncState: SyncState {
        get {
            access(keyPath: \.syncState)
            return _syncState
        }
        set {
            guard newValue != _syncState else { return }
            withMutation(keyPath: \.syncState) {
                _syncState = newValue
            }
        }
    }

    /// The underlying SDK sync service, exposed so that sub-services
    /// (e.g. `RoomListManager`) can obtain their own handles from it.
    private(set) var syncService: SyncService?

    /// Called when the sync service is rebuilt after a connectivity
    /// restoration. ``MatrixService`` sets this to re-wire
    /// ``RoomListManager`` to the new sync service.
    var onSyncServiceRestarted: ((SyncService) async throws -> Void)?

    /// Called when a saved session was restored offline and connectivity
    /// has returned. ``MatrixService`` sets this to retry the full
    /// `restoreSession` + `startSync` pipeline.
    var onPendingOnlineRestore: (() async -> Void)?

    /// Called when the sync service encounters an unrecoverable
    /// authentication error (e.g. `M_UNKNOWN_TOKEN` after a refresh
    /// token expires during sleep). ``MatrixService`` sets this to
    /// clear the invalid session and return the user to the login
    /// screen.
    var onAuthenticationFailure: (() async -> Void)?

    // MARK: - Private Properties

    private let networkMonitor: NetworkMonitor

    private var client: (any ClientProxyProtocol)?
    private var syncStateHandle: TaskHandle?
    private var phase: LifecyclePhase = .idle

    /// The single consumer task that processes all ``ConnectivityInput``
    /// events sequentially.
    private var eventLoopTask: Task<Void, Never>?

    /// The continuation for feeding events into the event loop.
    private var inputContinuation: AsyncStream<ConnectivityInput>.Continuation?

    /// The pending reconnect timer task.
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Reconnect backoff (truncated binary exponential)
    //
    // Same shape as Ethernet CSMA/CD's collision backoff: after the *n*th
    // consecutive failure, sleep a uniformly random number of slots in
    // [0, 2^n − 1] before retrying. `maxBackoffExponent` caps the window
    // so the wait saturates instead of growing without bound. A successful
    // sync resets `reconnectAttempt` to 0. Randomization avoids a
    // thundering herd of clients all retrying in lockstep after a shared
    // outage.
    private var reconnectAttempt: Int = 0
    private let baseSlotSeconds: Double = 1
    private let maxBackoffExponent: Int = 6

    // MARK: - Initialization

    init(networkMonitor: NetworkMonitor) {
        self.networkMonitor = networkMonitor
    }

    // MARK: - Public API

    /// Starts the sync service for the given client if not already running.
    ///
    /// Builds the SDK's `SyncService`, observes its state transitions,
    /// and waits for the first `.running` state before returning. Starts
    /// the unified event loop for network, sleep/wake, and SDK state
    /// observation.
    ///
    /// - Parameter client: The authenticated client proxy.
    /// - Throws: If sync fails to start or is cancelled.
    func startSync(client: any ClientProxyProtocol) async throws {
        guard phase == .idle || phase == .pendingRestore else { return }

        self.client = client
        syncState = .syncing
        ActivityLog.shared.log(
            category: .sync, severity: .info, source: "SyncManager",
            summary: "Starting sync"
        )

        try await buildAndStartSyncService(client: client)
        try Task.checkCancellation()

        // Wait for the first .running state (up to 15 seconds)
        let reachedRunning = await waitForFirstSync()
        reconnectAttempt = 0
        transitionPhase(to: .active)
        ActivityLog.shared.log(
            category: .sync, severity: reachedRunning ? .info : .warning, source: "SyncManager",
            summary: reachedRunning ? "Initial sync reached running state" : "Initial sync did not reach running state"
        )

        // Begin the unified event loop for connectivity management
        startEventLoop()

        // Re-wire the initial sync service's SDK state listener into the
        // event loop so SDK state changes are processed by processInput
        // rather than applied directly.
        if let syncService {
            wireSdkStateObserver(for: syncService)
        }
    }

    /// Marks the sync layer as "logged in but not yet able to talk to the
    /// homeserver" — used when ``AuthenticationService`` returned
    /// `.offlineWithSavedSession`. Sets ``syncState`` to `.offline`,
    /// triggering the existing offline banner, and starts the event loop
    /// so we can retry once connectivity returns.
    func enterPendingOnlineRestore() {
        transitionPhase(to: .pendingRestore)
        syncState = .offline
        // Start the network monitor so we get a callback when
        // connectivity comes back.
        networkMonitor.start()
        startEventLoop()
    }

    /// Stops the sync service, tears down the event loop, and resets all
    /// state. Called during logout to fully tear down the sync layer.
    func stop() async {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        syncStateHandle = nil

        if let syncService {
            await syncService.stop()
        }
        syncService = nil
        client = nil
        reconnectAttempt = 0
        onSyncServiceRestarted = nil
        onPendingOnlineRestore = nil
        onAuthenticationFailure = nil
        transitionPhase(to: .idle)
        syncState = .idle
    }

    // MARK: - Event Loop

    /// Creates the unified input stream and starts three producers
    /// (network, system lifecycle, SDK state) plus one consumer that
    /// processes events sequentially via ``processInput(_:)``.
    private func startEventLoop() {
        // Tear down any existing loop before starting a new one.
        eventLoopTask?.cancel()
        inputContinuation?.finish()

        let (stream, continuation) = AsyncStream<ConnectivityInput>.makeStream()
        inputContinuation = continuation

        // --- Producer 1: Network connectivity ---
        let networkTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let isConnected = await withCheckedContinuation { cont in
                    withObservationTracking {
                        _ = self.networkMonitor.isConnected
                    } onChange: {
                        Task { @MainActor in
                            cont.resume(returning: self.networkMonitor.isConnected)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                continuation.yield(isConnected ? .networkOnline : .networkOffline)
            }
        }

        // --- Producer 2: System sleep/wake ---
        let workspace = NSWorkspace.shared.notificationCenter
        let sleepName = NSWorkspace.willSleepNotification
        let wakeName = NSWorkspace.didWakeNotification

        nonisolated(unsafe) let sleepObserver = workspace.addObserver(
            forName: sleepName, object: nil, queue: .main
        ) { _ in continuation.yield(.systemWillSleep) }

        nonisolated(unsafe) let wakeObserver = workspace.addObserver(
            forName: wakeName, object: nil, queue: .main
        ) { _ in continuation.yield(.systemDidWake) }

        // --- Consumer ---
        eventLoopTask = Task { [weak self] in
            defer {
                networkTask.cancel()
                workspace.removeObserver(sleepObserver)
                workspace.removeObserver(wakeObserver)
            }

            for await input in stream {
                guard let self, !Task.isCancelled else { return }
                await self.processInput(input)
            }
        }
    }

    // MARK: - State Machine

    /// The core state transition function. Dispatches on `(phase, input)`
    /// to determine the correct action and new phase.
    private func processInput(_ input: ConnectivityInput) async {
        switch (phase, input) {

        // ── Active ──────────────────────────────────────────────────

        case (.active, .networkOffline):
            await tearDownSyncForOffline()

        case (.active, .systemWillSleep):
            await tearDownSyncForSleep()

        case (.active, .sdkState(.running)):
            syncState = .running
            ActivityLog.shared.log(
                category: .sync, severity: .info, source: "SyncManager",
                summary: "Sync state: running"
            )

        case (.active, .sdkState(.idle)):
            break

        case (.active, .sdkState(.offline)):
            ActivityLog.shared.log(
                category: .sync, severity: .warning, source: "SyncManager",
                summary: "SDK reported offline — transitioning to offline + backoff retry"
            )
            await tearDownSyncForOffline()
            scheduleReconnect()

        case (.active, .sdkState(.terminated)):
            ActivityLog.shared.log(
                category: .sync, severity: .error, source: "SyncManager",
                summary: "Sync service terminated"
            )
            syncState = .error("The sync service was terminated.")

        case (.active, .sdkState(.error)):
            ActivityLog.shared.log(
                category: .sync, severity: .error, source: "SyncManager",
                summary: "SDK sync error — transitioning to offline + backoff retry"
            )
            await tearDownSyncForOffline()
            scheduleReconnect()

        case (.active, .networkOnline),
             (.active, .reconnectTimerFired):
            break // Already active, nothing to do

        // ── Sleeping ────────────────────────────────────────────────

        case (.sleeping, .systemDidWake):
            await rebuildAfterWake()

        case (.sleeping, .networkOffline):
            // Network went away while we were sleeping. Publish
            // offline so the banner appears when the user returns.
            transitionPhase(to: .offline)
            syncState = .offline

        case (.sleeping, .networkOnline),
             (.sleeping, .systemWillSleep),
             (.sleeping, .sdkState),
             (.sleeping, .reconnectTimerFired):
            break // Wait for wake

        // ── Offline ─────────────────────────────────────────────────

        case (.offline, .networkOnline):
            await rebuildAfterOnline()

        case (.offline, .reconnectTimerFired):
            await rebuildAfterOnline()

        case (.offline, .networkOffline),
             (.offline, .sdkState),
             (.offline, .systemWillSleep),
             (.offline, .systemDidWake):
            break // Already offline, sync is stopped

        // ── Rebuilding ──────────────────────────────────────────────

        case (.rebuilding, .sdkState(.running)):
            // Rebuild succeeded — the SDK reached running state.
            // waitForFirstSync() will pick this up and complete.
            syncState = .running
            ActivityLog.shared.log(
                category: .sync, severity: .info, source: "SyncManager",
                summary: "Sync state: running (rebuild complete)"
            )

        case (.rebuilding, .sdkState(.error)),
             (.rebuilding, .sdkState(.offline)):
            // Suppress during rebuild — the rebuild's error handling
            // path will deal with this via waitForFirstSync().
            ActivityLog.shared.log(
                category: .sync, severity: .debug, source: "SyncManager",
                summary: "SDK state suppressed during rebuild",
                detail: "Input: \(input), phase: \(phase)"
            )

        case (.rebuilding, .sdkState(.terminated)):
            ActivityLog.shared.log(
                category: .sync, severity: .error, source: "SyncManager",
                summary: "Sync service terminated during rebuild"
            )
            syncState = .error("The sync service was terminated.")
            transitionPhase(to: .active) // Terminal — no recovery

        case (.rebuilding, .networkOffline):
            // Network went away during rebuild. Cancel the rebuild
            // (the current buildAndStartSyncService call will fail
            // or waitForFirstSync will time out) and go offline.
            // Note: we set phase immediately so the rebuild's error
            // handler knows not to schedule a reconnect.
            await tearDownSyncForOffline()

        case (.rebuilding, .systemWillSleep):
            // Sleep arrived during rebuild. Tear down to sleeping.
            await tearDownSyncForSleep()

        case (.rebuilding, .sdkState(.idle)),
             (.rebuilding, .networkOnline),
             (.rebuilding, .reconnectTimerFired),
             (.rebuilding, .systemDidWake):
            break // Ignore during rebuild

        // ── Pending Restore ─────────────────────────────────────────

        case (.pendingRestore, .networkOnline):
            ActivityLog.shared.log(
                category: .sync, severity: .info, source: "SyncManager",
                summary: "Retrying deferred session restore"
            )
            await onPendingOnlineRestore?()

        case (.pendingRestore, .networkOffline),
             (.pendingRestore, .sdkState),
             (.pendingRestore, .systemWillSleep),
             (.pendingRestore, .systemDidWake),
             (.pendingRestore, .reconnectTimerFired):
            break // Stay pending until network comes back

        // ── Idle (event loop should not be running) ──────────────────

        case (.idle, _):
            break

        // ── Catch-all for unknown SDK states ────────────────────────
        // SyncServiceState is a non-frozen SDK enum; future versions
        // may add new cases. Log and ignore.
        default:
            ActivityLog.shared.log(
                category: .sync, severity: .debug, source: "SyncManager",
                summary: "Unhandled input ignored",
                detail: "Input: \(input), phase: \(phase)"
            )
        }
    }

    // MARK: - Actions

    /// Stops the sync service and publishes `.offline`. Used when the
    /// network becomes unavailable or the SDK reports an error/offline
    /// state.
    private func tearDownSyncForOffline() async {
        reconnectTask?.cancel()
        reconnectTask = nil

        // Disable send queues so the SDK stops trying to deliver messages
        await client?.enableAllSendQueues(enable: false)

        syncStateHandle = nil
        if let syncService {
            await syncService.stop()
        }
        syncService = nil

        transitionPhase(to: .offline)
        syncState = .offline

        ActivityLog.shared.log(
            category: .sync, severity: .warning, source: "SyncManager",
            summary: "Sync service stopped — offline"
        )
    }

    /// Tears down the sync service before sleep **without** publishing
    /// `.offline`, so the UI doesn't flash a banner during routine
    /// sleep/wake cycles.
    private func tearDownSyncForSleep() async {
        reconnectTask?.cancel()
        reconnectTask = nil

        syncStateHandle = nil
        if let syncService {
            await syncService.stop()
        }
        syncService = nil

        transitionPhase(to: .sleeping)

        ActivityLog.shared.log(
            category: .sync, severity: .info, source: "SyncManager",
            summary: "System sleep — tearing down sync service"
        )
    }

    /// Rebuilds the sync service after the system wakes from sleep.
    /// No settling delay is needed because ``NetworkMonitor`` debounces
    /// path changes.
    private func rebuildAfterWake() async {
        guard let client else { return }

        ActivityLog.shared.log(
            category: .sync, severity: .info, source: "SyncManager",
            summary: "System wake — rebuilding sync service"
        )
        reconnectAttempt = 0
        await rebuildSyncService(client: client)
    }

    /// Rebuilds the sync service when connectivity is restored or a
    /// reconnect timer fires.
    private func rebuildAfterOnline() async {
        guard let client else { return }

        ActivityLog.shared.log(
            category: .sync, severity: .info, source: "SyncManager",
            summary: "Rebuilding sync service",
            detail: "Reconnect attempt #\(reconnectAttempt)"
        )
        await rebuildSyncService(client: client)
    }

    /// Shared rebuild logic for both wake and online recovery.
    ///
    /// Sets ``phase`` to `.rebuilding`, builds the sync service with
    /// offline mode, waits for `.running`, and notifies sub-services
    /// on success. On failure, transitions to `.offline` and schedules
    /// a backoff retry.
    private func rebuildSyncService(client: any ClientProxyProtocol) async {
        transitionPhase(to: .rebuilding)

        do {
            try await buildAndStartSyncService(client: client, offlineMode: true)
            try Task.checkCancellation()

            let reached = await waitForFirstSync()

            // Another event (e.g. networkOffline, systemWillSleep) may
            // have changed the phase while we were waiting. If so, the
            // rebuild is moot — the new phase's handler already ran.
            guard phase == .rebuilding else { return }

            guard reached else {
                ActivityLog.shared.log(
                    category: .sync, severity: .warning, source: "SyncManager",
                    summary: "Rebuild did not reach running state"
                )
                transitionPhase(to: .offline)
                syncState = .offline
                scheduleReconnect()
                return
            }

            await client.enableAllSendQueues(enable: true)
            transitionPhase(to: .active)
            reconnectAttempt = 0

            if let syncService {
                try await onSyncServiceRestarted?(syncService)
            }
        } catch is CancellationError {
            // Shutdown in progress — don't overwrite state
        } catch {
            // Another event may have changed the phase during the
            // failed build attempt.
            guard phase == .rebuilding else { return }

            if NetworkErrorClassifier.isAuthenticationError(error) {
                ActivityLog.shared.log(
                    category: .sync, severity: .error, source: "SyncManager",
                    summary: "Rebuild failed — session invalidated",
                    detail: error.localizedDescription
                )
                // The refresh token expired (e.g. during an extended
                // sleep). This is unrecoverable without re-authentication.
                // Notify MatrixService so it can clean up and return the
                // user to the login screen.
                await onAuthenticationFailure?()
            } else if NetworkErrorClassifier.isOfflineShaped(error) {
                ActivityLog.shared.log(
                    category: .sync, severity: .warning, source: "SyncManager",
                    summary: "Rebuild failed (server unreachable)",
                    detail: error.localizedDescription
                )
                transitionPhase(to: .offline)
                syncState = .offline
                scheduleReconnect()
            } else {
                ActivityLog.shared.log(
                    category: .sync, severity: .error, source: "SyncManager",
                    summary: "Rebuild failed",
                    detail: error.localizedDescription
                )
                transitionPhase(to: .active) // Terminal — no recovery
                syncState = .error("Failed to restart sync: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    /// Builds the SDK `SyncService`, subscribes to its state, and starts
    /// it.
    ///
    /// When the event loop is running (``inputContinuation`` is non-nil),
    /// SDK state changes are routed through the unified input stream.
    /// During the initial sync (before the event loop starts), state
    /// changes are applied directly to ``syncState`` so that
    /// ``waitForFirstSync()`` can observe them.
    ///
    /// - Parameters:
    ///   - client: The authenticated client proxy.
    ///   - offlineMode: Whether to enable offline mode (used on restarts
    ///     to initialize from local cache before syncing with the server).
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

        syncStateHandle = nil
        wireSdkStateObserver(for: service)

        await service.start()
        syncService = service
    }

    /// Subscribes to the SDK sync service's state changes.
    ///
    /// The listener always applies `.running` directly to ``syncState``
    /// so that ``waitForFirstSync()`` can observe it — even when the
    /// event loop's consumer task is blocked inside `rebuildSyncService`.
    /// The ``syncState`` setter's deduplication prevents double-firing
    /// when the event loop also processes the same `.running` event.
    ///
    /// When the event loop is running, the listener also yields events
    /// into the input stream so ``processInput(_:)`` can perform
    /// phase-specific handling (logging suppressed states, scheduling
    /// reconnects, etc.). During initial startup (no event loop), error
    /// states are applied directly for `waitForFirstSync()` visibility.
    private func wireSdkStateObserver(for service: SyncService) {
        let continuation = inputContinuation
        let listener = SDKListener<SyncServiceState> { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .running:
                    // Always apply directly so waitForFirstSync() sees it
                    // even when the event loop is blocked in a rebuild.
                    self.syncState = .running
                case .error, .terminated:
                    // Only apply directly when the event loop isn't running
                    // (initial sync). Otherwise let processInput handle it
                    // to avoid a brief .error flash before transitioning to
                    // the correct offline/retry state.
                    if continuation == nil {
                        self.syncState = .error("Sync service error during initial sync.")
                    }
                case .idle, .offline:
                    break
                }
            }
            // Route through the event loop for phase-aware handling.
            continuation?.yield(.sdkState(state))
        }
        syncStateHandle = service.state(listener: listener)
    }

    /// Schedules a retry using truncated binary exponential backoff.
    /// Yields `.reconnectTimerFired` into the input stream after the
    /// delay, so the retry is processed sequentially by the event loop.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let attempt = min(reconnectAttempt, maxBackoffExponent)
        let upperBound = max(1, 1 << attempt) // at attempt=0 → 1 slot
        let slots = Int.random(in: 0..<upperBound)
        let delay = Double(slots) * baseSlotSeconds
        reconnectAttempt += 1
        ActivityLog.shared.log(
            category: .sync, severity: .info, source: "SyncManager",
            summary: "Scheduling reconnect attempt #\(reconnectAttempt)",
            detail: "Delay: \(String(format: "%.1f", delay))s (slot \(slots)/\(upperBound), exponent \(attempt))"
        )
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.inputContinuation?.yield(.reconnectTimerFired)
        }
    }

    /// Transitions ``phase`` and logs the change for diagnostics.
    private func transitionPhase(to newPhase: LifecyclePhase) {
        let oldPhase = phase
        phase = newPhase
        if oldPhase != newPhase {
            ActivityLog.shared.log(
                category: .sync, severity: .debug, source: "SyncManager",
                summary: "Phase: \(oldPhase) → \(newPhase)"
            )
        }
    }

    /// Polls until ``syncState`` reaches `.running`, returning `true` on
    /// success. Returns `false` if an `.error` state is observed or the
    /// 15-second timeout elapses.
    ///
    /// Note: `.offline` is NOT treated as a terminal failure here because
    /// during a rebuild the event loop suppresses `.offline` transitions
    /// to ``syncState``, so the pre-existing `.offline` value may still
    /// be present while the new sync service starts up.
    private func waitForFirstSync() async -> Bool {
        for _ in 0..<30 {
            switch syncState {
            case .running:
                return true
            case .error:
                return false
            case .idle, .syncing, .offline:
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return syncState == .running
    }
}
