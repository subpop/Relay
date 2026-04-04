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

// RoomDirectorySearchProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// A proxy that wraps the Matrix SDK `RoomDirectorySearch`.
///
/// Provides paginated search of the homeserver's public room directory
/// with observable results updated via SDK listener callbacks.
///
/// Call ``startListening()`` after initialization to begin receiving
/// results updates from the SDK.
@Observable
public final class RoomDirectorySearchProxy: RoomDirectorySearchProxyProtocol, @unchecked Sendable {
    private let search: RoomDirectorySearch
    @ObservationIgnored nonisolated(unsafe) private var resultsHandle: TaskHandle?
    private let lock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _storage: [RoomDescription] = []

    /// The current list of room descriptions from the search.
    public private(set) var results: [RoomDescription] = []

    /// Creates a room directory search proxy.
    ///
    /// - Parameter search: The SDK room directory search instance.
    public init(search: RoomDirectorySearch) {
        self.search = search
    }

    deinit {
        resultsHandle?.cancel()
    }

    /// Subscribes to search result updates from the SDK.
    ///
    /// Call this once after initialization to begin receiving results.
    public func startListening() async { // swiftlint:disable:this cyclomatic_complexity
        let listener = SDKListener<[RoomDirectorySearchEntryUpdate]> { [weak self] updates in
            guard let self else { return }
            lock.lock()
            for update in updates {
                switch update {
                case .append(let values):
                    _storage.append(contentsOf: values)
                case .clear:
                    _storage.removeAll()
                case .pushFront(let value):
                    _storage.insert(value, at: 0)
                case .pushBack(let value):
                    _storage.append(value)
                case .popFront:
                    if !_storage.isEmpty { _storage.removeFirst() }
                case .popBack:
                    if !_storage.isEmpty { _storage.removeLast() }
                case .insert(let index, let value):
                    _storage.insert(value, at: Int(index))
                case .set(let index, let value):
                    _storage[Int(index)] = value
                case .remove(let index):
                    _storage.remove(at: Int(index))
                case .truncate(let length):
                    _storage = Array(_storage.prefix(Int(length)))
                case .reset(let values):
                    _storage = values
                }
            }
            let snapshot = _storage
            lock.unlock()
            Task { @MainActor [weak self] in
                self?.results = snapshot
            }
        }
        resultsHandle = await search.results(listener: listener)
    }

    public func search(filter: String?, batchSize: UInt32, viaServerName: String?) async throws {
        try await search.search(filter: filter, batchSize: batchSize, viaServerName: viaServerName)
    }

    public func nextPage() async throws {
        try await search.nextPage()
    }

    public func isAtLastPage() async throws -> Bool {
        try await search.isAtLastPage()
    }

    public func loadedPages() async throws -> UInt32 {
        try await search.loadedPages()
    }
}
