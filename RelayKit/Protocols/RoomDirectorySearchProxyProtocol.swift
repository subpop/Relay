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

// RoomDirectorySearchProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// Searches the homeserver's public room directory.
///
/// Provides paginated search results. Call ``search(filter:batchSize:)``
/// to start a new search, then ``nextPage()`` to load additional results.
/// Observe ``results`` for the current list of matching rooms, or call
/// ``waitForNextUpdate(after:)`` to suspend until new results arrive.
///
/// ## Topics
///
/// ### Results
/// - ``results``
/// - ``updateCounter``
/// - ``waitForNextUpdate(after:)``
///
/// ### Searching
/// - ``search(filter:batchSize:viaServerName:)``
/// - ``nextPage()``
/// - ``isAtLastPage()``
/// - ``loadedPages()``
public protocol RoomDirectorySearchProxyProtocol: AnyObject, Sendable {
    /// The current list of room descriptions from the search.
    var results: [RoomDescription] { get }

    /// The current update counter. Record this before starting an operation,
    /// then pass it to ``waitForNextUpdate(after:)`` to await new results.
    var updateCounter: UInt64 { get }

    /// Suspends until the SDK listener delivers a non-empty results snapshot
    /// with an update counter greater than `previousCounter`.
    ///
    /// - Parameter previousCounter: The counter value recorded before the operation.
    /// - Returns: The latest results snapshot from the SDK.
    func waitForNextUpdate(after previousCounter: UInt64) async -> [RoomDescription]

    /// Starts a new search with the given filter.
    ///
    /// - Parameters:
    ///   - filter: An optional search filter string.
    ///   - batchSize: The number of results per page.
    ///   - viaServerName: An optional server name to search via.
    /// - Throws: If the search fails.
    func search(filter: String?, batchSize: UInt32, viaServerName: String?) async throws

    /// Loads the next page of search results.
    ///
    /// - Throws: If loading fails or no more pages are available.
    func nextPage() async throws

    /// Whether the last page of results has been loaded.
    ///
    /// - Returns: `true` if at the last page.
    func isAtLastPage() async throws -> Bool

    /// The number of pages loaded so far.
    ///
    /// - Returns: The page count.
    func loadedPages() async throws -> UInt32
}
