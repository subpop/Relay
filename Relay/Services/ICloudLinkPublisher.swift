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

/// Uploads a file to Relay's iCloud Drive folder and returns a public
/// download link for it.
nonisolated enum ICloudLinkPublisher {
    /// The iCloud container shared files are copied into.
    static let containerIdentifier = "iCloud.app.subpop.Relay"

    enum PublishError: LocalizedError {
        case unavailable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "iCloud Drive is not available. Sign in to iCloud in System Settings.", comment: "Error reason: the iCloud container could not be reached")
            case .timedOut:
                String(localized: "The upload to iCloud took too long.", comment: "Error reason: the iCloud upload did not finish in time")
            }
        }
    }

    /// Whether the user is signed in to iCloud.
    static var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Copies `fileURL` into iCloud Drive as `filename`, waits for the upload
    /// to finish, and returns a link anyone can use to download it.
    ///
    /// The copy is removed from iCloud Drive if the upload fails or the
    /// task is cancelled.
    static func publishLink(for fileURL: URL, filename: String) async throws -> URL {
        let fileManager = FileManager.default
        guard let container = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            throw PublishError.unavailable
        }
        let folder = container
            .appending(path: "Documents", directoryHint: .isDirectory)
            .appending(path: "Shared Files", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = folder.appending(path: filename, directoryHint: .notDirectory)

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(at: fileURL, to: destination)
            try await waitForUpload(of: destination)
            return try fileManager.url(forPublishingUbiquitousItemAt: destination, expiration: nil)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// Polls until iCloud reports the item as uploaded.
    private static func waitForUpload(of url: URL) async throws {
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey]
        let deadline = ContinuousClock.now + .seconds(30 * 60)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            if let error = values.ubiquitousItemUploadingError { throw error }
            if values.ubiquitousItemIsUploaded == true { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw PublishError.timedOut
    }
}
