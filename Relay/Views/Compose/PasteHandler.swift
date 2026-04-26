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
import OSLog

private let logger = Logger(subsystem: "Relay", category: "PasteHandler")

/// Monitors Cmd+V key events and intercepts paste when the system pasteboard
/// contains file URLs (Finder copy), raw image data, or raw video data — but
/// not plain text, which is left for the TextField to handle normally.
@Observable
final class PasteHandler {
    var pastedURLs: [URL]?
    private var monitor: Any?

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v"
            else { return event }

            if self?.extractPastedContent() == true { return nil }
            return event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stopMonitoring()
        }
    }

    // MARK: - Extraction

    private func extractPastedContent() -> Bool {
        let pasteboard = NSPasteboard.general

        // File URLs from Finder or other file managers. Checked first because
        // Finder also puts the filename as plain text on the pasteboard.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            pastedURLs = urls
            return true
        }

        // Plain text without file URLs — let the TextField handle it.
        if pasteboard.string(forType: .string) != nil { return false }

        // Raw image data (screenshots, "Copy Image", etc.)
        if let url = extractRawImage(from: pasteboard) {
            pastedURLs = [url]
            return true
        }

        // Raw video data
        if let url = extractRawVideo(from: pasteboard) {
            pastedURLs = [url]
            return true
        }

        return false
    }

    // MARK: - Raw Image

    /// Image pasteboard types in preference order. TIFF is last because it is
    /// the generic macOS image pasteboard format and needs conversion to PNG.
    private static let imageTypes: [(type: NSPasteboard.PasteboardType, ext: String)] = [
        (.png, ".png"),
        (NSPasteboard.PasteboardType("public.jpeg"), ".jpg"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), ".gif"),
        (NSPasteboard.PasteboardType("org.webmproject.webp"), ".webp"),
        (NSPasteboard.PasteboardType("public.heic"), ".heic"),
        (.tiff, ".png"),
    ]

    private func extractRawImage(from pasteboard: NSPasteboard) -> URL? {
        for (type, ext) in Self.imageTypes {
            guard let rawData = pasteboard.data(forType: type) else { continue }

            let data: Data
            if type == .tiff {
                guard let rep = NSBitmapImageRep(data: rawData),
                      let png = rep.representation(using: .png, properties: [:])
                else { continue }
                data = png
            } else {
                data = rawData
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString + "-Pasted Image" + ext)
            do {
                try data.write(to: tempURL)
                return tempURL
            } catch {
                logger.error("Failed to write pasted image to temp file: \(error)")
                continue
            }
        }
        return nil
    }

    // MARK: - Raw Video

    private static let videoTypes: [(type: NSPasteboard.PasteboardType, ext: String)] = [
        (NSPasteboard.PasteboardType("public.mpeg-4"), ".mp4"),
        (NSPasteboard.PasteboardType("com.apple.quicktime-movie"), ".mov"),
        (NSPasteboard.PasteboardType("public.avi"), ".avi"),
    ]

    private func extractRawVideo(from pasteboard: NSPasteboard) -> URL? {
        for (type, ext) in Self.videoTypes {
            guard let data = pasteboard.data(forType: type) else { continue }

            let tempURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString + "-Pasted Video" + ext)
            do {
                try data.write(to: tempURL)
                return tempURL
            } catch {
                logger.error("Failed to write pasted video to temp file: \(error)")
                continue
            }
        }
        return nil
    }
}
