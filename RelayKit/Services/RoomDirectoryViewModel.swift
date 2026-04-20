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

// RoomDirectoryViewModel.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import RelayInterface
import os

private let logger = Logger(subsystem: "RelayKit", category: "RoomDirectoryViewModel")

/// The concrete implementation of ``RoomDirectoryViewModelProtocol`` backed by the Matrix Rust SDK.
///
/// ``RoomDirectoryViewModel`` wraps the SDK's `RoomDirectorySearch` API with
/// observable, paginated results. It loads an initial batch of popular rooms
/// on first search and supports incremental page loading.
@Observable
public final class RoomDirectoryViewModel: RoomDirectoryViewModelProtocol {
    public private(set) var rooms: [DirectoryRoom] = []
    public private(set) var isSearching = false
    public private(set) var isAtEnd = false
    private let client: any ClientProxyProtocol
    private var searchProxy: RoomDirectorySearchProxy?
    private let errorReporter: ErrorReporter

    /// Creates a room directory view model.
    ///
    /// - Parameter client: The authenticated client proxy.
    public init(client: any ClientProxyProtocol, errorReporter: ErrorReporter) {
        self.client = client
        self.errorReporter = errorReporter
    }

    public func search(query: String?) async {
        isSearching = true
        rooms = []
        isAtEnd = false

        do {
            let proxy = RoomDirectorySearchProxy(search: client.roomDirectorySearch())
            await proxy.startListening()
            self.searchProxy = proxy

            let filter = (query ?? "").trimmingCharacters(in: .whitespaces)
            let counterBefore = proxy.updateCounter
            try await proxy.search(
                filter: filter.isEmpty ? nil : filter,
                batchSize: 20,
                viaServerName: nil
            )

            // Wait for the SDK listener to deliver results.
            let snapshot = await proxy.waitForNextUpdate(after: counterBefore)
            rooms = snapshot.map { $0.toDirectoryRoom() }
            isAtEnd = await checkIsAtLastPage(proxy)
        } catch is CancellationError {
            // Ignore cancellation
        } catch {
            logger.error("Directory search failed: \(error)")
            errorReporter.report(.roomJoinFailed(error.localizedDescription))
        }

        isSearching = false
    }

    public func loadMore() async {
        guard let proxy = searchProxy, !isAtEnd, !isSearching else { return }
        isSearching = true

        do {
            let counterBefore = proxy.updateCounter
            try await proxy.nextPage()

            // Wait for the SDK listener to deliver updated results.
            let snapshot = await proxy.waitForNextUpdate(after: counterBefore)
            rooms = snapshot.map { $0.toDirectoryRoom() }
            isAtEnd = await checkIsAtLastPage(proxy)
        } catch is CancellationError {
            // Ignore cancellation
        } catch {
            logger.error("Directory load more failed: \(error)")
            errorReporter.report(.roomJoinFailed(error.localizedDescription))
        }

        isSearching = false
    }

    /// Checks whether the proxy has reached the last page of results.
    ///
    /// The SDK updates its pagination state asynchronously after the listener
    /// delivers result entries. A brief yield gives the SDK time to process
    /// the server's pagination token before we query `isAtLastPage()`.
    private func checkIsAtLastPage(_ proxy: RoomDirectorySearchProxy) async -> Bool {
        try? await Task.sleep(for: .milliseconds(100))
        return (try? await proxy.isAtLastPage()) ?? true
    }
}

// MARK: - RoomDescription Mapping

private extension RoomDescription {
    func toDirectoryRoom() -> DirectoryRoom {
        DirectoryRoom(
            roomId: roomId,
            name: name,
            topic: topic,
            alias: alias,
            avatarURL: avatarUrl,
            memberCount: joinedMembers,
            isWorldReadable: isWorldReadable
        )
    }
}
