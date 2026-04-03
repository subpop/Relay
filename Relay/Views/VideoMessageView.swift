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

import AVFoundation
import QuickLook
import RelayInterface
import SwiftUI
import UniformTypeIdentifiers

/// Renders a video attachment with a thumbnail preview, play button overlay,
/// download button, and QuickLook support on double-click.
struct VideoMessageView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.mediaAutoReveal) private var autoReveal
    @Environment(\.errorReporter) private var errorReporter
    let message: TimelineMessage

    @State private var thumbnail: NSImage?
    @State private var isLoading = true
    @State private var isHovering = false
    @State private var quickLookURL: URL?
    @State private var isLoadingMedia = false
    @State private var isRevealed = false
    @State private var cachedVideoFileURL: URL?

    private var mediaInfo: TimelineMessage.MediaInfo {
        message.mediaInfo!
    }

    private var displaySize: CGSize {
        let maxWidth: CGFloat = 280
        let maxHeight: CGFloat = 320
        if let w = mediaInfo.width, let h = mediaInfo.height, w > 0, h > 0 {
            let aspect = CGFloat(w) / CGFloat(h)
            let width = min(CGFloat(w), maxWidth)
            let height = width / aspect
            if height > maxHeight {
                return CGSize(width: maxHeight * aspect, height: maxHeight)
            }
            return CGSize(width: width, height: height)
        }
        return CGSize(width: maxWidth, height: 180)
    }

    private var shouldShow: Bool { autoReveal || isRevealed }

    var body: some View {
        ZStack {
            if shouldShow {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray).opacity(0.15))
                        .frame(width: displaySize.width, height: displaySize.height)
                        .overlay {
                            if isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "play.rectangle")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            } else {
                Rectangle()
                    .fill(Color(.systemGray).opacity(0.15))
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Media Hidden")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onTapGesture { isRevealed = true }
            }
        }
        .overlay {
            if shouldShow, !isLoadingMedia, thumbnail != nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .shadow(radius: 4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if shouldShow {
                HStack(spacing: 4) {
                    if let duration = mediaInfo.duration, duration > 0 {
                        Text(formatDuration(duration))
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    if isHovering {
                        downloadButton
                    }
                }
                .padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if shouldShow, let caption = mediaInfo.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(8)
            }
        }
        .onTapGesture(count: 2) {
            if shouldShow {
                Task { await openQuickLook() }
            }
        }
        .overlay {
            if isLoadingMedia {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay { ProgressView() }
            }
        }
        .quickLookPreview($quickLookURL)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .task(id: shouldShow ? mediaInfo.mxcURL : nil) {
            guard shouldShow else { return }
            isLoading = true

            // Try server-side thumbnail first.
            if let data = await matrixService.mediaThumbnail(
                mxcURL: mediaInfo.mxcURL,
                width: UInt64(displaySize.width * 2),
                height: UInt64(displaySize.height * 2)
            ) {
                thumbnail = NSImage(data: data)
            }

            // Fall back to extracting a frame from the video locally.
            if thumbnail == nil, let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(mediaInfo.filename)
                if let _ = try? data.write(to: tempURL) {
                    cachedVideoFileURL = tempURL
                    let asset = AVURLAsset(url: tempURL)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(
                        width: displaySize.width * 2,
                        height: displaySize.height * 2
                    )
                    if let cgImage = try? await generator.image(at: .zero).image {
                        thumbnail = NSImage(cgImage: cgImage, size: .zero)
                    }
                }
            }

            isLoading = false
        }
    }

    private var downloadButton: some View {
        Button {
            Task { await saveMedia() }
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.5))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
    }

    private func openQuickLook() async {
        guard !isLoadingMedia else { return }
        isLoadingMedia = true
        defer { isLoadingMedia = false }

        let url: URL
        if let cached = cachedVideoFileURL, FileManager.default.fileExists(atPath: cached.path) {
            url = cached
        } else {
            guard let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) else { return }
            url = FileManager.default.temporaryDirectory.appendingPathComponent(mediaInfo.filename)
            do {
                try data.write(to: url)
                cachedVideoFileURL = url
            } catch {
                errorReporter.report(.mediaPreviewFailed(filename: mediaInfo.filename, reason: error.localizedDescription))
                return
            }
        }
        quickLookURL = url
    }

    private func saveMedia() async {
        let data: Data
        if let cached = cachedVideoFileURL, let d = try? Data(contentsOf: cached) {
            data = d
        } else if let d = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) {
            data = d
        } else {
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = mediaInfo.filename
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url)
        } catch {
            errorReporter.report(.mediaSaveFailed(filename: mediaInfo.filename, reason: error.localizedDescription))
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins >= 60 {
            let hours = mins / 60
            let remainingMins = mins % 60
            return String(format: "%d:%02d:%02d", hours, remainingMins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}
