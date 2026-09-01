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

import Network
import Observation
import RelayInterface

/// Monitors network connectivity using `NWPathMonitor` and exposes reactive
/// state for use by ``SyncManager``.
///
/// ``NetworkMonitor`` uses the `Network` framework's path monitor to detect
/// connectivity changes. A **1.5-second debounce** absorbs transient path
/// flaps (e.g. adapter re-enumeration after wake, dock hot-plug, WiFi
/// roaming) so that ``isConnected`` only transitions after the path status
/// has been stable for the full settling interval. This prevents downstream
/// consumers from triggering expensive sync teardown/rebuild cycles on
/// every momentary blip.
///
/// ```swift
/// let monitor = NetworkMonitor()
/// monitor.start()
/// // Observe monitor.isConnected for changes
/// ```
@Observable
@MainActor
final class NetworkMonitor {
    /// Whether the device currently has a viable network path.
    ///
    /// This value is debounced: it only updates after the raw
    /// `NWPathMonitor` path status has been stable for
    /// ``settlingInterval``.
    private(set) var isConnected: Bool = true

    /// How long the raw path status must remain stable before
    /// ``isConnected`` is updated. Symmetric for both directions
    /// (going offline and coming online).
    private static let settlingInterval: Duration = .milliseconds(1500)

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let monitorQueue = DispatchQueue(
        label: "relay.network-monitor",
        qos: .utility
    )

    /// The most recently reported raw path status from `NWPathMonitor`,
    /// before debounce settling. `nil` when no change is pending.
    @ObservationIgnored private var pendingStatus: Bool?

    /// The active debounce timer. Cancelled and restarted on every raw
    /// path update; only fires if the status remains stable for the
    /// full ``settlingInterval``.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Starts monitoring network connectivity.
    ///
    /// Creates an `NWPathMonitor` and begins observing path updates.
    /// Raw path changes are debounced before updating ``isConnected``.
    func start() {
        guard monitor == nil else { return }

        let pathMonitor = NWPathMonitor()
        monitor = pathMonitor

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settlePathStatus(satisfied)
            }
        }

        pathMonitor.start(queue: monitorQueue)
        ActivityLog.shared.log(
            category: .network, severity: .debug, source: "NetworkMonitor",
            summary: "Network monitoring started"
        )
    }

    /// Stops monitoring network connectivity and releases resources.
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingStatus = nil
        monitor?.cancel()
        monitor = nil
        isConnected = true
        ActivityLog.shared.log(
            category: .network, severity: .debug, source: "NetworkMonitor",
            summary: "Network monitoring stopped"
        )
    }

    // MARK: - Private

    /// Debounces a raw path status change. Restarts the settling timer
    /// on every call; the published ``isConnected`` only updates if the
    /// status remains stable for the full ``settlingInterval``.
    private func settlePathStatus(_ satisfied: Bool) {
        pendingStatus = satisfied
        debounceTask?.cancel()

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settlingInterval)
            guard let self, !Task.isCancelled else { return }

            self.pendingStatus = nil
            guard self.isConnected != satisfied else { return }
            self.isConnected = satisfied

            if satisfied {
                ActivityLog.shared.log(
                    category: .network, severity: .info, source: "NetworkMonitor",
                    summary: "Network connectivity restored"
                )
            } else {
                ActivityLog.shared.log(
                    category: .network, severity: .warning, source: "NetworkMonitor",
                    summary: "Network connectivity lost"
                )
            }
        }

        // Log transient flaps for diagnostics when the pending status
        // differs from the last settled value but may not survive the
        // debounce window.
        if satisfied != isConnected {
            ActivityLog.shared.log(
                category: .network, severity: .debug, source: "NetworkMonitor",
                summary: "Path status change pending",
                detail: "Raw: \(satisfied ? "satisfied" : "unsatisfied"), settling for \(Self.settlingInterval)"
            )
        }
    }
}
