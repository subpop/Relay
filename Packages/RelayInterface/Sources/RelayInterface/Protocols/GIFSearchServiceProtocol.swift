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

import SwiftUI

/// A provider-agnostic service for searching animated GIF images.
///
/// Implementations wrap a specific GIF provider's API (e.g. GIPHY, Tenor) and
/// return results as ``GIFSearchResult`` values. Views program against this
/// protocol so the concrete provider can be swapped without changing view code.
public protocol GIFSearchServiceProtocol: Sendable {
    /// Searches for GIFs matching the given query.
    ///
    /// - Parameters:
    ///   - query: The search term or phrase.
    ///   - offset: The starting position for pagination.
    ///   - limit: The maximum number of results to return.
    /// - Returns: An array of matching GIF results.
    func search(query: String, offset: Int, limit: Int) async throws -> [GIFSearchResult]

    /// Returns currently trending GIFs.
    ///
    /// - Parameters:
    ///   - offset: The starting position for pagination.
    ///   - limit: The maximum number of results to return.
    /// - Returns: An array of trending GIF results.
    func trending(offset: Int, limit: Int) async throws -> [GIFSearchResult]

    /// Fires a provider analytics pingback for a user action (view, click, send).
    ///
    /// Implementations should make a best-effort `GET` request to the URL and
    /// silently discard any errors. This method is called with the analytics URLs
    /// from ``GIFSearchResult``.
    ///
    /// - Parameter url: The analytics pingback URL to fire.
    func registerAction(url: URL) async

    /// Downloads the full GIF data from the given URL.
    ///
    /// - Parameter url: The URL of the GIF to download (typically ``GIFSearchResult/originalURL``).
    /// - Returns: The raw GIF data.
    func downloadGIF(url: URL) async throws -> Data
}

// MARK: - Environment Key

private struct GIFSearchServiceKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any GIFSearchServiceProtocol = PlaceholderGIFSearchService()
}

/// SwiftUI environment accessor for the shared ``GIFSearchServiceProtocol`` instance.
public extension EnvironmentValues {
    /// The GIF search service used for searching and downloading animated GIFs.
    var gifSearchService: any GIFSearchServiceProtocol {
        get { self[GIFSearchServiceKey.self] }
        set { self[GIFSearchServiceKey.self] = newValue }
    }
}

/// A no-op placeholder used as the default environment value before injection.
@Observable
private final class PlaceholderGIFSearchService: GIFSearchServiceProtocol {
    func search(query: String, offset: Int, limit: Int) async throws -> [GIFSearchResult] { [] }
    func trending(offset: Int, limit: Int) async throws -> [GIFSearchResult] { [] }
    func registerAction(url: URL) async {}
    func downloadGIF(url: URL) async throws -> Data { Data() }
}
