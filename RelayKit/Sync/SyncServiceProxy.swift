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

// SyncServiceProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Observation

/// An `@Observable` proxy that wraps the Matrix SDK `SyncService`.
///
/// Manages the sliding sync lifecycle and provides reactive state
/// updates for SwiftUI views. The ``state`` property updates automatically
/// as the sync service transitions between states.
///
/// ```swift
/// struct SyncStatusView: View {
///     let sync: SyncServiceProxy
///
///     var body: some View {
///         switch sync.state {
///         case .running: Text("Connected")
///         case .offline: Text("Offline")
///         case .error:   Text("Error")
///         default:       ProgressView()
///         }
///     }
/// }
/// ```
@Observable
public final class SyncServiceProxy: SyncServiceProxyProtocol, @unchecked Sendable {
    private let syncService: SyncService
    @ObservationIgnored nonisolated(unsafe) private var stateTaskHandle: TaskHandle?

    /// The current sync service state.
    public private(set) var state: SyncServiceState = .idle

    /// An async stream of sync service state transitions.
    public let stateUpdates: AsyncStream<SyncServiceState>
    private let stateUpdatesContinuation: AsyncStream<SyncServiceState>.Continuation

    /// Creates a sync service proxy.
    ///
    /// - Parameter syncService: The SDK sync service instance.
    public init(syncService: SyncService) {
        self.syncService = syncService

        let (stream, continuation) = AsyncStream<SyncServiceState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stateUpdates = stream
        self.stateUpdatesContinuation = continuation

        stateTaskHandle = syncService.state(listener: SDKListener { [weak self] state in
            Task { @MainActor in self?.state = state }
            continuation.yield(state)
        })
    }

    deinit {
        stateTaskHandle?.cancel()
        stateUpdatesContinuation.finish()
    }

    /// Starts the sliding sync connection.
    public func start() async {
        await syncService.start()
    }

    /// Stops the sliding sync connection gracefully.
    public func stop() async {
        await syncService.stop()
    }

    /// Returns the room list service for managing room lists.
    public func roomListService() -> RoomListService {
        syncService.roomListService()
    }
}
