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
import SwiftUI
import UniformTypeIdentifiers

/// The entry point for the Relay macOS share extension.
///
/// When another app shares content (images, videos, files, URLs) and the user
/// selects Relay from the share sheet, the system instantiates this view
/// controller. It presents a SwiftUI ``ShareView`` with a room picker and
/// handles copying shared items to the app group container for deferred
/// sending by the main app.
class ShareViewController: NSViewController {
    override func loadView() {
        let rooms = ShareExtensionRoomProvider.loadRooms()

        // Extract attachment count and load a thumbnail for the header preview.
        var attachmentCount = 0
        var thumbnailProvider: NSItemProvider?
        for inputItem in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            for provider in inputItem.attachments ?? [] {
                attachmentCount += 1
                if thumbnailProvider == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    thumbnailProvider = provider
                }
            }
        }

        let shareView = ShareView(
            rooms: rooms,
            attachmentCount: attachmentCount,
            onSend: { [weak self] roomId in
                await self?.handleSend(roomId: roomId)
            },
            onCancel: { [weak self] in
                self?.cancel()
            },
            thumbnailProvider: thumbnailProvider
        )

        let hostingView = NSHostingView(rootView: shareView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        self.view = hostingView
    }

    // MARK: - Send Handling

    private func handleSend(roomId: String) async {
        guard let extensionContext else { return }
        guard let pendingDir = pendingSharesDirectoryURL() else {
            extensionContext.cancelRequest(withError: ShareError.containerUnavailable)
            return
        }

        var savedFilenames: [String] = []

        for inputItem in extensionContext.inputItems as? [NSExtensionItem] ?? [] {
            for provider in inputItem.attachments ?? [] {
                if let filename = await copyAttachment(provider: provider, to: pendingDir) {
                    savedFilenames.append(filename)
                }
            }
        }

        guard !savedFilenames.isEmpty else {
            extensionContext.cancelRequest(withError: ShareError.noAttachments)
            return
        }

        let share = PendingShare(
            roomId: roomId,
            filenames: savedFilenames
        )
        savePendingShare(share)

        // Signal the main app to pick up this pending share. We write the
        // share ID to the app group container and activate the app by
        // bundle ID to avoid the URL-based dispatch that creates a new window.
        writeLatestShareId(share.id)

        guard let bundleId = Bundle.main.object(forInfoDictionaryKey: "RelayMainAppBundleIdentifier") as? String else {
            fatalError("RelayMainAppBundleIdentifier missing from RelayShareExtension's Info.plist")
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }

        extensionContext.completeRequest(returningItems: nil)
    }

    // MARK: - File Handling

    private func copyAttachment(provider: NSItemProvider, to directory: URL) async -> String? {
        let supportedTypes: [UTType] = [.image, .movie, .audio, .pdf, .data]
        guard let matchingType = supportedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: matchingType.identifier) { url, error in
                guard let url, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let filename = "\(UUID().uuidString)-\(url.lastPathComponent)"
                let destination = directory.appending(path: filename)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: filename)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - App Group Container

    private static let pendingSharesDir = {
        #if DEBUG
        "pending-shares-debug"
        #else
        "pending-shares"
        #endif
    }()

    private static let manifestFilename = {
        #if DEBUG
        "pending-shares-debug.json"
        #else
        "pending-shares.json"
        #endif
    }()

    private func pendingSharesDirectoryURL() -> URL? {
        guard let container = AppGroup.containerURL else { return nil }
        let url = container.appending(
            path: Self.pendingSharesDir,
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func savePendingShare(_ share: PendingShare) {
        guard let container = AppGroup.containerURL else { return }
        let manifestURL = container.appending(path: Self.manifestFilename)

        var existing: [PendingShare] = []
        if let data = try? Data(contentsOf: manifestURL) {
            existing = (try? JSONDecoder().decode([PendingShare].self, from: data)) ?? []
        }
        existing.append(share)

        if let data = try? JSONEncoder().encode(existing) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    /// Writes the latest share ID to the app group container so the main app
    /// knows which pending share to pick up on activation.
    private func writeLatestShareId(_ id: UUID) {
        guard let container = AppGroup.containerURL else { return }
        let url = container.appending(path: "latest-share-id.txt")
        try? id.uuidString.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Cancel

    private func cancel() {
        extensionContext?.cancelRequest(withError: ShareError.cancelled)
    }
}

// MARK: - PendingShare (local copy)

/// Lightweight copy of the ``PendingShare`` model for the share extension.
///
/// The extension cannot link RelayInterface (which depends on AppKit via
/// ``MatrixServiceProtocol``), so it uses its own identical Codable struct.
private struct PendingShare: Codable {
    let id: UUID
    let roomId: String
    let filenames: [String]
    let timestamp: Date

    init(roomId: String, filenames: [String]) {
        self.id = UUID()
        self.roomId = roomId
        self.filenames = filenames
        self.timestamp = .now
    }
}

// MARK: - Errors

private enum ShareError: Error, LocalizedError {
    case containerUnavailable
    case noAttachments
    case cancelled

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            "Could not access shared container."
        case .noAttachments:
            "No attachments found to share."
        case .cancelled:
            "Share cancelled."
        }
    }
}
