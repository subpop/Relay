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
import OSLog
import RelayInterface

private let logger = Logger(subsystem: "RelayKit", category: "GiphyService")

/// A concrete ``GIFSearchServiceProtocol`` implementation backed by the GIPHY API.
///
/// This service communicates with `api.giphy.com` to search and fetch trending GIFs.
/// All GIPHY-specific types are kept private; only ``GIFSearchResult`` crosses the
/// boundary, keeping the rest of the app provider-agnostic.
public final class GiphyService: GIFSearchServiceProtocol {
    // MARK: - Configuration

    /// The GIPHY API key, provided at init time.
    ///
    /// Use the build-time generated `Secrets.giphyAPIKey` from the app target
    /// to pass the XOR-obfuscated key without committing it to source control.
    private let apiKey: String

    /// Content rating filter. Defaults to PG for safe content.
    private let rating: String

    private let session: URLSession
    private let baseURL = "https://api.giphy.com/v1/gifs"

    /// Creates a GIPHY service with the given API key.
    ///
    /// - Parameters:
    ///   - apiKey: The GIPHY API key.
    ///   - rating: Content rating filter (default: `"pg"`).
    public init(apiKey: String = "", rating: String = "pg") {
        self.apiKey = apiKey
        self.rating = rating
        self.session = URLSession.shared
    }

    // MARK: - GIFSearchServiceProtocol

    public func search(query: String, offset: Int, limit: Int) async throws -> [GIFSearchResult] {
        var components = URLComponents(string: "\(baseURL)/search")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: rating),
            URLQueryItem(name: "lang", value: Locale.current.language.languageCode?.identifier ?? "en")
        ]

        guard let url = components.url else {
            throw GiphyError.invalidURL
        }

        return try await fetchGIFs(from: url)
    }

    public func trending(offset: Int, limit: Int) async throws -> [GIFSearchResult] {
        var components = URLComponents(string: "\(baseURL)/trending")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: rating)
        ]

        guard let url = components.url else {
            throw GiphyError.invalidURL
        }

        return try await fetchGIFs(from: url)
    }

    public func registerAction(url: URL) async {
        // Fire-and-forget analytics pingback. Append timestamp and discard errors.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "ts", value: String(Int(Date.now.timeIntervalSince1970 * 1000))))
        components?.queryItems = items

        guard let pingbackURL = components?.url else { return }

        do {
            let (_, _) = try await session.data(from: pingbackURL)
        } catch {
            await logger
                .debug(
                    "Analytics pingback failed: \(error.localizedDescription)"
                )
        }
    }

    public func downloadGIF(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GiphyError.downloadFailed
        }

        return data
    }

    // MARK: - Private

    private func fetchGIFs(from url: URL) async throws -> [GIFSearchResult] {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GiphyError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            await logger
                .error("GIPHY API returned status \(httpResponse.statusCode)")
            throw GiphyError.httpError(statusCode: httpResponse.statusCode)
        }

        let giphyResponse = try JSONDecoder().decode(GiphyResponse.self, from: data)
        return giphyResponse.data.compactMap { gif in
            gif.toSearchResult()
        }
    }
}

// MARK: - Errors

nonisolated enum GiphyError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid GIPHY API URL."
        case .invalidResponse: "Invalid response from GIPHY API."
        case .httpError(let code): "GIPHY API error (HTTP \(code))."
        case .downloadFailed: "Failed to download GIF."
        }
    }
}

// MARK: - GIPHY API Response Models (Private)

// MARK: - GIPHY API Response Models

/// These types are nonisolated to opt out of the project's default MainActor
/// isolation, since they are decoded on arbitrary threads by URLSession.

/// Top-level GIPHY API response.
nonisolated private struct GiphyResponse: Decodable, Sendable {
    let data: [GiphyGIF]
    let pagination: GiphyPagination?
}

nonisolated private struct GiphyPagination: Decodable, Sendable {
    let offset: Int?
    let totalCount: Int?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case offset
        case totalCount = "total_count"
        case count
    }
}

/// A single GIF object from the GIPHY API.
nonisolated private struct GiphyGIF: Decodable, Sendable {
    let id: String
    let title: String?
    let altText: String?
    let images: GiphyImages
    let user: GiphyUser?
    let analytics: GiphyAnalytics?

    enum CodingKeys: String, CodingKey {
        case id, title, images, user, analytics
        case altText = "alt_text"
    }

    /// Converts this GIPHY-specific object into a provider-agnostic ``GIFSearchResult``.
    func toSearchResult() -> GIFSearchResult? {
        // Use fixed_height for preview (200px tall, good for grids)
        guard let preview = images.fixedHeight,
              let previewURLString = preview.url,
              let previewURL = URL(string: previewURLString) else {
            return nil
        }

        // Use original for sending
        guard let original = images.original,
              let originalURLString = original.url,
              let originalURL = URL(string: originalURLString) else {
            return nil
        }

        let previewWidth = Double(preview.width ?? "0") ?? 0
        let previewHeight = Double(preview.height ?? "0") ?? 0
        let originalWidth = Double(original.width ?? "0") ?? 0
        let originalHeight = Double(original.height ?? "0") ?? 0

        return GIFSearchResult(
            id: id,
            title: title ?? "",
            previewURL: previewURL,
            previewSize: CGSize(width: previewWidth, height: previewHeight),
            originalURL: originalURL,
            originalSize: CGSize(width: originalWidth, height: originalHeight),
            altText: altText,
            username: user?.displayName ?? user?.username,
            onloadURL: analytics?.onload?.url.flatMap(URL.init(string:)),
            onclickURL: analytics?.onclick?.url.flatMap(URL.init(string:)),
            onsentURL: analytics?.onsent?.url.flatMap(URL.init(string:))
        )
    }
}

/// The images/renditions object containing various GIF formats and sizes.
nonisolated private struct GiphyImages: Decodable, Sendable {
    let fixedHeight: GiphyRendition?
    let fixedHeightStill: GiphyRendition?
    let fixedWidth: GiphyRendition?
    let original: GiphyRendition?
    let originalStill: GiphyRendition?
    let downsized: GiphyRendition?
    let previewGif: GiphyRendition?

    enum CodingKeys: String, CodingKey {
        case fixedHeight = "fixed_height"
        case fixedHeightStill = "fixed_height_still"
        case fixedWidth = "fixed_width"
        case original
        case originalStill = "original_still"
        case downsized
        case previewGif = "preview_gif"
    }
}

/// A single rendition with URL, dimensions, and optional size info.
nonisolated private struct GiphyRendition: Decodable, Sendable {
    let url: String?
    let width: String?
    let height: String?
    let size: String?
    let mp4: String?
    let webp: String?
}

/// The user/creator who uploaded the GIF.
nonisolated private struct GiphyUser: Decodable, Sendable {
    let username: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
    }
}

/// Analytics tracking URLs for view/click/send events.
nonisolated private struct GiphyAnalytics: Decodable, Sendable {
    let onload: GiphyAnalyticsAction?
    let onclick: GiphyAnalyticsAction?
    let onsent: GiphyAnalyticsAction?
}

nonisolated private struct GiphyAnalyticsAction: Decodable, Sendable {
    let url: String?
}
