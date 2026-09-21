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
import MatrixKit
import UniformTypeIdentifiers

/// Shared helpers for downloading media content to disk for preview and save operations.
///
/// Used by ``ImageMessageView``, ``VideoMessageView``, ``AudioMessageView``,
/// and ``FileMessageView`` to avoid duplicating the download-write-present logic.
enum MediaFileHelper {
    /// A media download target: plaintext MXC URL and/or encrypted file dict.
    struct Download: Hashable, Sendable {
        var mxcURL: String
        var filename: String
        var mimetype: String?
        var size: Int?
        var encryptedFile: EncryptedFile?
        /// Server-generated thumbnail MXC URL (unencrypted), if any.
        var thumbnailMXCURL: String?
        /// Encrypted thumbnail reference from the event metadata, if any.
        var encryptedThumbnail: EncryptedFile?

        init(
            mxcURL: String,
            filename: String,
            mimetype: String? = nil,
            size: Int? = nil,
            encryptedFile: EncryptedFile? = nil,
            thumbnailMXCURL: String? = nil,
            encryptedThumbnail: EncryptedFile? = nil
        ) {
            self.mxcURL = mxcURL
            self.filename = filename
            self.mimetype = mimetype
            self.size = size
            self.encryptedFile = encryptedFile
            self.thumbnailMXCURL = thumbnailMXCURL
            self.encryptedThumbnail = encryptedThumbnail
        }
    }

    /// Returns a unique temporary file URL for the given download.
    ///
    /// The filename is prefixed with a short hash derived from the MXC URL (or
    /// the encrypted file URL) so that different media items with the same
    /// filename (e.g. `image.png`) never collide. The file is placed directly
    /// in the temporary directory (no subdirectory) so the QuickLook XPC
    /// service can always access it. The original file extension is preserved
    /// so QuickLook identifies the content type correctly.
    static func temporaryFileURL(for download: Download) -> URL {
        let hash = Insecure.MD5
            .hash(data: Data(download.mxcURL.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = (download.filename as NSString).pathExtension
        let base = (download.filename as NSString).deletingPathExtension
        let uniqueName = ext.isEmpty ? "\(hash)-\(base)" : "\(hash)-\(base).\(ext)"
        return FileManager.default.temporaryDirectory
            .appending(path: uniqueName)
    }

    /// Downloads media content and writes it to a temporary file.
    ///
    /// - Parameters:
    ///   - download: The media target (plaintext URL, encrypted file, or both).
    ///   - client: The client used to download media content.
    /// - Returns: The file URL of the written temporary file.
    /// - Throws: If the media cannot be downloaded or the file cannot be written.
    static func downloadToTemporaryFile(
        download: Download,
        client: RelayClient
    ) async throws -> URL {
        guard let data = await fetch(download: download, client: client) else {
            throw MediaFileError.downloadFailed
        }

        let url = temporaryFileURL(for: download)
        try data.write(to: url)
        return url
    }

    /// Downloads media content and presents an NSSavePanel for saving to disk.
    ///
    /// - Parameters:
    ///   - download: The media target (plaintext URL, encrypted file, or both).
    ///   - client: The client used to download media content.
    ///   - contentTypes: The allowed content types for the save panel.
    ///   - data: Pre-downloaded data to use instead of fetching. Pass `nil` to download.
    /// - Throws: If the media cannot be downloaded or written.
    static func saveToFile(
        download: Download,
        client: RelayClient,
        contentTypes: [UTType],
        data existingData: Data? = nil
    ) async throws {
        let data: Data
        if let existingData {
            data = existingData
        } else {
            guard let downloaded = await fetch(download: download, client: client) else {
                throw MediaFileError.downloadFailed
            }
            data = downloaded
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = download.filename
        panel.allowedContentTypes = contentTypes
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url)
    }

    /// Fetch bytes, preferring the encrypted file dict when present.
    static func fetch(download: Download, client: RelayClient) async -> Data? {
        await client.mediaBytes(download)
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

extension ObservableTimelineEvent {
    /// A download target for image, video, audio, file, and sticker events,
    /// or nil for other kinds or when the event carries no MXC URL.
    ///
    /// Encrypted attachments resolve through the event-level
    /// ``ObservableTimelineEvent/encryptedFile``; encrypted thumbnails
    /// resolve through the metadata's `thumbnailFile`.
    var mediaDownload: MediaFileHelper.Download? {
        let body: String
        let url: String?
        let info: MediaInfo?
        switch kind {
        case .image(let b, let u, let i), .video(let b, let u, let i),
            .audio(let b, let u, let i), .file(let b, let u, let i),
            .sticker(let b, let u, let i):
            body = b
            url = u
            info = i
        default:
            return nil
        }
        // Encrypted attachments carry no `url`; their MXC lives in the
        // encrypted file dict.
        guard let mxcURL = url ?? encryptedFile?.url else { return nil }
        return MediaFileHelper.Download(
            mxcURL: mxcURL,
            // The body doubles as the caption when it differs from the
            // original filename; prefer the real filename for display
            // and saved files.
            filename: filename ?? body,
            mimetype: info?.mimeType,
            size: info?.size,
            encryptedFile: encryptedFile,
            thumbnailMXCURL: info?.thumbnailUrl,
            encryptedThumbnail: info?.thumbnailFile
        )
    }
}
