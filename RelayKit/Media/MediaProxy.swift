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

// MediaProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Provides media upload and download operations via the Matrix content repository.
///
/// Wraps the media-related methods on ``ClientProxy`` for convenient
/// use throughout the application.
///
/// ## Topics
///
/// ### Downloading
/// - ``getContent(source:)``
/// - ``getThumbnail(source:width:height:)``
///
/// ### Uploading
/// - ``upload(mimeType:data:progressWatcher:)``
public final class MediaProxy: @unchecked Sendable {
    private let client: any ClientProxyProtocol

    /// Creates a media proxy.
    ///
    /// - Parameter client: The client proxy for media operations.
    public init(client: any ClientProxyProtocol) {
        self.client = client
    }

    /// Downloads media content from the homeserver.
    ///
    /// - Parameter source: The media source to download.
    /// - Returns: The media data.
    /// - Throws: `ClientError` if the download fails.
    public func getContent(source: MediaSource) async throws -> Data {
        try await client.getMediaContent(mediaSource: source)
    }

    /// Downloads a thumbnail for media content.
    ///
    /// - Parameters:
    ///   - source: The media source.
    ///   - width: The desired width in pixels.
    ///   - height: The desired height in pixels.
    /// - Returns: The thumbnail data.
    /// - Throws: `ClientError` if the download fails.
    public func getThumbnail(source: MediaSource, width: UInt64, height: UInt64) async throws -> Data {
        try await client.getMediaThumbnail(mediaSource: source, width: width, height: height)
    }

    /// Uploads media data to the homeserver.
    ///
    /// - Parameters:
    ///   - mimeType: The MIME type of the media.
    ///   - data: The media data.
    ///   - progressWatcher: An optional progress watcher.
    /// - Returns: The MXC URI of the uploaded media.
    /// - Throws: `ClientError` if the upload fails.
    public func upload(mimeType: String, data: Data, progressWatcher: ProgressWatcher? = nil) async throws -> String {
        try await client.uploadMedia(mimeType: mimeType, data: data, progressWatcher: progressWatcher)
    }
}
