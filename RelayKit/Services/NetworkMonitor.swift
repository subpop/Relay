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
import os

private let logger = Logger(subsystem: "RelayKit", category: "Network")

/// Monitors network connectivity using `NWPathMonitor` and exposes reactive
/// state for use by ``SyncManager``.
///
/// ``NetworkMonitor`` uses the `Network` framework's path monitor to detect
/// connectivity changes. When the network becomes unavailable, ``isConnected``
/// transitions to `false`, signaling sync services to stop. When connectivity
/// is restored, it transitions back to `true`, triggering sync restart.
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
    private(set) var isConnected: Bool = true

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let monitorQueue = DispatchQueue(
        label: "relay.network-monitor",
        qos: .utility
    )

    /// Starts monitoring network connectivity.
    ///
    /// Creates an `NWPathMonitor` and begins observing path updates.
    /// Connectivity changes are forwarded to the main actor.
    func start() {
        guard monitor == nil else { return }

        let pathMonitor = NWPathMonitor()
        monitor = pathMonitor

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.isConnected
                self.isConnected = satisfied

                if previous != satisfied {
                    if satisfied {
                        logger.info("Network connectivity restored")
                    } else {
                        logger.info("Network connectivity lost")
                    }
                }
            }
        }

        pathMonitor.start(queue: monitorQueue)
        logger.debug("Network monitoring started")
    }

    /// Stops monitoring network connectivity and releases resources.
    func stop() {
        monitor?.cancel()
        monitor = nil
        isConnected = true
        logger.debug("Network monitoring stopped")
    }
}
