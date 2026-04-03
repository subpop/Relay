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
import os

private let logger = Logger(subsystem: "RelayKit", category: "Media")

/// Caches and fetches Matrix media content (avatars, thumbnails, and full-resolution media).
///
/// ``MediaService`` wraps the SDK's media download APIs with in-memory `NSCache` layers
/// to avoid redundant network requests. Both avatar thumbnails (as `NSImage`) and raw
/// media data (as `Data`) are cached separately.
@MainActor
final class MediaService {
    private let avatarCache = NSCache<NSString, NSImage>()
    private let mediaCache = NSCache<NSString, NSData>()

    /// Downloads and returns a thumbnail of a Matrix media URL as an `NSImage`.
    ///
    /// Results are cached in memory to avoid redundant network requests.
    ///
    /// - Parameters:
    ///   - mxcURL: The `mxc://` URL of the media.
    ///   - size: The desired display size in points (the actual download is at 2x scale).
    ///   - client: The authenticated client proxy.
    /// - Returns: The thumbnail image, or `nil` if the download failed.
    func avatarThumbnail(mxcURL: String, size: CGFloat, client: any ClientProxyProtocol) async -> NSImage? {
        let scale = 2.0
        let px = UInt64(size * scale)
        let cacheKey = "\(mxcURL)_\(px)" as NSString

        if let cached = avatarCache.object(forKey: cacheKey) {
            return cached
        }

        do {
            let source = try MediaSource.fromUrl(url: mxcURL)
            let data = try await client.getMediaThumbnail(mediaSource: source, width: px, height: px)
            guard let image = NSImage(data: data) else { return nil }
            avatarCache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }

    /// Downloads the full-resolution content of a Matrix media URL.
    ///
    /// Results are cached in memory.
    ///
    /// - Parameters:
    ///   - mxcURL: The `mxc://` URL of the media.
    ///   - client: The authenticated client proxy.
    /// - Returns: The raw media data, or `nil` if the download failed.
    func mediaContent(mxcURL: String, client: any ClientProxyProtocol) async -> Data? {
        let cacheKey = mxcURL as NSString
        if let cached = mediaCache.object(forKey: cacheKey) {
            return cached as Data
        }
        do {
            let source = try MediaSource.fromUrl(url: mxcURL)
            let data = try await client.getMediaContent(mediaSource: source)
            mediaCache.setObject(data as NSData, forKey: cacheKey)
            return data
        } catch {
            return nil
        }
    }

    /// Downloads a thumbnail of a Matrix media URL at the specified pixel dimensions.
    ///
    /// Results are cached in memory.
    ///
    /// - Parameters:
    ///   - mxcURL: The `mxc://` URL of the media.
    ///   - width: The desired thumbnail width in pixels.
    ///   - height: The desired thumbnail height in pixels.
    ///   - client: The authenticated client proxy.
    /// - Returns: The thumbnail data, or `nil` if the download failed.
    func mediaThumbnail(mxcURL: String, width: UInt64, height: UInt64, client: any ClientProxyProtocol) async -> Data? {
        let cacheKey = "\(mxcURL)_thumb_\(width)x\(height)" as NSString
        if let cached = mediaCache.object(forKey: cacheKey) {
            return cached as Data
        }
        do {
            let source = try MediaSource.fromUrl(url: mxcURL)
            let data = try await client.getMediaThumbnail(mediaSource: source, width: width, height: height)
            mediaCache.setObject(data as NSData, forKey: cacheKey)
            return data
        } catch {
            return nil
        }
    }
}
