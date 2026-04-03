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

// RoomListServiceProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Observation

/// An `@Observable` proxy that wraps the Matrix SDK `RoomListService`.
///
/// Provides reactive state and sync indicator updates for the room list.
/// SwiftUI views can bind directly to ``state`` and ``syncIndicator``.
@Observable
public final class RoomListServiceProxy: RoomListServiceProxyProtocol, @unchecked Sendable {
    private let service: RoomListService
    @ObservationIgnored nonisolated(unsafe) private var stateTaskHandle: TaskHandle?
    @ObservationIgnored nonisolated(unsafe) private var syncIndicatorTaskHandle: TaskHandle?

    /// The current room list service state.
    public private(set) var state: RoomListServiceState = .initial

    /// The current sync indicator visibility.
    public private(set) var syncIndicator: RoomListServiceSyncIndicator = .hide

    /// An async stream of room list service state transitions.
    public let stateUpdates: AsyncStream<RoomListServiceState>
    private let stateUpdatesContinuation: AsyncStream<RoomListServiceState>.Continuation

    /// An async stream of sync indicator visibility changes.
    public let syncIndicatorUpdates: AsyncStream<RoomListServiceSyncIndicator>
    private let syncIndicatorUpdatesContinuation: AsyncStream<RoomListServiceSyncIndicator>.Continuation

    /// Creates a room list service proxy.
    ///
    /// - Parameter service: The SDK room list service instance.
    public init(service: RoomListService) {
        self.service = service

        let (stateStream, stateContinuation) = AsyncStream<RoomListServiceState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stateUpdates = stateStream
        self.stateUpdatesContinuation = stateContinuation

        let (indicatorStream, indicatorContinuation) = AsyncStream<RoomListServiceSyncIndicator>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.syncIndicatorUpdates = indicatorStream
        self.syncIndicatorUpdatesContinuation = indicatorContinuation

        stateTaskHandle = service.state(listener: SDKListener { [weak self] state in
            Task { @MainActor in self?.state = state }
            stateContinuation.yield(state)
        })

        syncIndicatorTaskHandle = service.syncIndicator(
            delayBeforeShowingInMs: 1000,
            delayBeforeHidingInMs: 0,
            listener: SDKListener { [weak self] indicator in
                Task { @MainActor in self?.syncIndicator = indicator }
                indicatorContinuation.yield(indicator)
            }
        )
    }

    deinit {
        stateTaskHandle?.cancel()
        syncIndicatorTaskHandle?.cancel()
        stateUpdatesContinuation.finish()
        syncIndicatorUpdatesContinuation.finish()
    }

    /// Returns the room list containing all rooms.
    public func allRooms() async throws -> RoomList {
        try await service.allRooms()
    }

    /// Returns a room by its Matrix room ID.
    public func room(id: String) throws -> Room {
        try service.room(roomId: id)
    }

    /// Subscribes to updates for the specified rooms.
    public func subscribeToRooms(roomIds: [String]) async throws {
        try await service.subscribeToRooms(roomIds: roomIds)
    }
}
