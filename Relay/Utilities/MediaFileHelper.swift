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
import CryptoKit
import RelayInterface
import UniformTypeIdentifiers

/// Shared helpers for downloading media content to disk for preview and save operations.
///
/// Used by ``ImageMessageView``, ``VideoMessageView``, ``AudioMessageView``,
/// and ``FileMessageView`` to avoid duplicating the download-write-present logic.
enum MediaFileHelper {

    /// Returns a unique temporary file URL for the given media info.
    ///
    /// The filename is prefixed with a short hash derived from the MXC URL so
    /// that different media items with the same filename (e.g. `image.png`)
    /// never collide. The file is placed directly in the temporary directory
    /// (no subdirectory) so the QuickLook XPC service can always access it.
    /// The original file extension is preserved so QuickLook identifies the
    /// content type correctly.
    static func temporaryFileURL(for mediaInfo: TimelineMessage.MediaInfo) -> URL {
        let hash = Insecure.MD5
            .hash(data: Data(mediaInfo.mxcURL.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = (mediaInfo.filename as NSString).pathExtension
        let base = (mediaInfo.filename as NSString).deletingPathExtension
        let uniqueName = ext.isEmpty ? "\(hash)-\(base)" : "\(hash)-\(base).\(ext)"
        return FileManager.default.temporaryDirectory
            .appending(path: uniqueName)
    }

    /// Downloads media content and writes it to a temporary file.
    ///
    /// - Parameters:
    ///   - mediaInfo: The media metadata containing the MXC URL and filename.
    ///   - matrixService: The service used to download media content.
    /// - Returns: The file URL of the written temporary file.
    /// - Throws: If the media cannot be downloaded or the file cannot be written.
    static func downloadToTemporaryFile(
        mediaInfo: TimelineMessage.MediaInfo,
        matrixService: any MatrixServiceProtocol
    ) async throws -> URL {
        guard let data = await matrixService.mediaContent(
            mxcURL: mediaInfo.mxcURL,
            mediaSourceJSON: mediaInfo.mediaSourceJSON
        ) else {
            throw MediaFileError.downloadFailed
        }

        let url = temporaryFileURL(for: mediaInfo)
        try data.write(to: url)
        return url
    }

    /// Downloads media content and presents an NSSavePanel for saving to disk.
    ///
    /// - Parameters:
    ///   - mediaInfo: The media metadata containing the MXC URL and filename.
    ///   - matrixService: The service used to download media content.
    ///   - contentTypes: The allowed content types for the save panel.
    ///   - data: Pre-downloaded data to use instead of fetching. Pass `nil` to download.
    /// - Throws: If the media cannot be downloaded or written.
    static func saveToFile(
        mediaInfo: TimelineMessage.MediaInfo,
        matrixService: any MatrixServiceProtocol,
        contentTypes: [UTType],
        data existingData: Data? = nil
    ) async throws {
        let data: Data
        if let existingData {
            data = existingData
        } else {
            guard let downloaded = await matrixService.mediaContent(
                mxcURL: mediaInfo.mxcURL,
                mediaSourceJSON: mediaInfo.mediaSourceJSON
            ) else {
                throw MediaFileError.downloadFailed
            }
            data = downloaded
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = mediaInfo.filename
        panel.allowedContentTypes = contentTypes
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url)
    }

    /// Errors specific to media file operations.
    enum MediaFileError: LocalizedError {
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed: "Failed to download media content."
            }
        }
    }
}
