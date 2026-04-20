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

import QuickLook
import RelayInterface
import SwiftUI
import UniformTypeIdentifiers

/// Renders an image attachment with thumbnail loading, tap-to-reveal for hidden media,
/// double-click QuickLook preview, and a download/save button on hover.
struct ImageMessageView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.mediaAutoReveal) private var autoReveal
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.gifAnimationOverride) private var gifAnimationOverride
    @AppStorage("behavior.animateGIFs") private var globalAnimateGIFs = GIFAnimationMode.onHover

    private var animateGIFs: GIFAnimationMode {
        if let override = gifAnimationOverride, let mode = GIFAnimationMode(rawValue: override) {
            return mode
        }
        return globalAnimateGIFs
    }
    let message: TimelineMessage

    @State private var image: NSImage?
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var isHovering = false
    @State private var quickLookURL: URL?
    @State private var isLoadingFullImage = false
    @State private var isRevealed = false

    private var mediaInfo: TimelineMessage.MediaInfo {
        message.mediaInfo!
    }

    private var displaySize: CGSize {
        let maxWidth: CGFloat = 280
        let maxHeight: CGFloat = 320
        // swiftlint:disable:next identifier_name
        if let w = mediaInfo.width, let h = mediaInfo.height, w > 0, h > 0 {
            let aspect = CGFloat(w) / CGFloat(h)
            let width = min(CGFloat(w), maxWidth)
            let height = width / aspect
            if height > maxHeight {
                return CGSize(width: maxHeight * aspect, height: maxHeight)
            }
            return CGSize(width: width, height: height)
        }
        return CGSize(width: maxWidth, height: 200)
    }

    /// Whether this message contains a GIF image, detected by MIME type or file extension.
    private var isGIF: Bool {
        if let mime = mediaInfo.mimetype, mime.lowercased() == "image/gif" {
            return true
        }
        return mediaInfo.filename.lowercased().hasSuffix(".gif")
    }

    /// Whether the GIF should currently be animating, based on the user preference.
    private var shouldAnimateGIF: Bool {
        switch animateGIFs {
        case .always: true
        case .onHover: isHovering
        case .never: false
        }
    }

    private var shouldShow: Bool { autoReveal || isRevealed }

    var body: some View {
        ZStack {
            if shouldShow {
                if isGIF, let imageData {
                    AnimatedImageView(data: imageData, isAnimating: shouldAnimateGIF)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .clipped()
                } else if let image {
                    Image(nsImage: image)
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
                                Image(systemName: "photo")
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
        .overlay(alignment: .bottomTrailing) {
            if shouldShow, image != nil {
                downloadButton
                    .padding(8)
                    .opacity(isHovering ? 1 : 0)
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
            if isLoadingFullImage {
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
            if isGIF {
                // Load full content for GIFs to preserve animation frames.
                if let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) {
                    imageData = data
                    image = NSImage(data: data)
                }
            } else {
                if let data = await matrixService.mediaThumbnail(
                    mxcURL: mediaInfo.mxcURL,
                    width: UInt64(displaySize.width * 2),
                    height: UInt64(displaySize.height * 2)
                ) {
                    image = NSImage(data: data)
                }
            }
            isLoading = false
        }
    }

    private var downloadButton: some View {
        Button {
            Task { await saveImage() }
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
        guard !isLoadingFullImage else { return }
        isLoadingFullImage = true
        defer { isLoadingFullImage = false }

        guard let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) else { return }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(mediaInfo.filename)
        do {
            try data.write(to: url)
            quickLookURL = url
        } catch {
            errorReporter.report(.mediaPreviewFailed(filename: mediaInfo.filename, reason: error.localizedDescription))
        }
    }

    private func saveImage() async {
        guard let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = mediaInfo.filename
        panel.allowedContentTypes = [.image]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url)
        } catch {
            errorReporter.report(.mediaSaveFailed(filename: mediaInfo.filename, reason: error.localizedDescription))
        }
    }
}
