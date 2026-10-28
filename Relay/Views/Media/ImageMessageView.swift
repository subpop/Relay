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

import MatrixKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Renders an image attachment with thumbnail loading, tap-to-reveal for hidden media,
/// click-to-zoom QuickLook preview, and a download/save button on hover.
struct ImageMessageView: View {
    @Environment(RelayClient.self) private var client
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
    let item: MediaItem

    /// Upload progress (0 to 1) when this image is still being sent, or nil
    /// once uploaded. Drawn as a thin bar over the bottom of the placeholder.
    var uploadProgress: Double? = nil

    /// Side length for a square gallery tile; nil renders at the media's own size.
    var tileSize: CGFloat? = nil

    /// Whether the image is a sticker: shown whole, with its description as a
    /// tooltip, and without the zoom, download, and caption affordances.
    var isSticker = false

    init(
        item: MediaItem, uploadProgress: Double? = nil, tileSize: CGFloat? = nil,
        isSticker: Bool = false
    ) {
        self.item = item
        self.uploadProgress = uploadProgress
        self.tileSize = tileSize
        self.isSticker = isSticker
    }

    @State private var image: NSImage?
    @State private var imageData: Data?
    @State private var animatedFrames: AnimatedImageFrames?
    @State private var isLoading = true
    @State private var isHovering = false
    @State private var quickLookURL: URL?
    @State private var isLoadingFullImage = false
    @State private var isRevealed = false
    /// Why the full-size image couldn't be loaded, set when QuickLook fell
    /// back to presenting the thumbnail.
    @State private var fullSizeError: String?

    private var download: MediaFileHelper.Download? { item.download }

    private var displaySize: CGSize {
        if let tileSize { return CGSize(width: tileSize, height: tileSize) }
        return item.info?.displaySize() ?? CGSize(width: 280, height: 200)
    }

    /// Whether this message contains a GIF image, detected by MIME type or file extension.
    private var isGIF: Bool {
        if let mime = download?.mimetype, mime.lowercased() == "image/gif" {
            return true
        }
        return (download?.filename ?? "").lowercased().hasSuffix(".gif")
    }

    /// Whether this message contains a WebP image, detected by MIME type or file extension.
    private var isWebP: Bool {
        if let mime = download?.mimetype, mime.lowercased() == "image/webp" {
            return true
        }
        return (download?.filename ?? "").lowercased().hasSuffix(".webp")
    }

    /// Whether an animated image should currently be animating, based on the user preference.
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
                } else if let animatedFrames {
                    AnimatedFramesView(frames: animatedFrames, isAnimating: shouldAnimateGIF)
                        .aspectRatio(contentMode: isSticker ? .fit : .fill)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .clipped()
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: isSticker ? .fit : .fill)
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
        .overlay {
            if shouldShow, !isSticker, !isGIF, animatedFrames == nil, image != nil {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.ultraThinMaterial)
                    .shadow(radius: 2)
                    .opacity(isHovering ? 0.8 : 0)
                    .scaleEffect(isHovering ? 1.25 : 0.85)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if shouldShow, !isSticker, image != nil {
                downloadButton
                    .padding(8)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .overlay(alignment: .topLeading) {
            if shouldShow, let fullSizeError {
                Label("Full-size image unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(.capsule)
                    .padding(8)
                    .help(fullSizeError)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if shouldShow, !isSticker, tileSize == nil, let caption = item.caption {
                Text(caption)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(.rect(cornerRadius: 8))
                    .padding(8)
            }
        }
        .onTapGesture {
            if shouldShow, !isSticker {
                Task { await openQuickLook() }
            }
        }
        .overlay(alignment: .bottom) {
            if let uploadProgress {
                ProgressView(value: uploadProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Uploading attachment")
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
        .help(isSticker ? item.fallbackName : "")
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .task(id: shouldShow ? download?.mxcURL : nil) {
            guard shouldShow, let download else { return }
            isLoading = true
            if ImageAnimation.loadsOriginal(
                isAnimated: item.info?.isAnimated, isGIF: isGIF, isWebP: isWebP)
            {
                // Server thumbnails are static, so animation needs the original.
                if let data = await client.mediaBytes(download) {
                    if isGIF {
                        imageData = data
                    } else {
                        animatedFrames = AnimatedImageFrames(data: data)
                    }
                    image = NSImage(data: data)
                }
            } else {
                if let data = await client.mediaThumbnail(
                    download,
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
        guard !isLoadingFullImage, let download else { return }
        isLoadingFullImage = true
        defer { isLoadingFullImage = false }

        do {
            let url = try await MediaFileHelper.downloadToTemporaryFile(
                download: download, client: client
            )
            // Resign first responder so QLPreviewPanel can find the
            // SwiftUI .quickLookPreview handler in the responder chain.
            // Without this, an active ComposeInputTextView keeps the
            // panel from locating its data source.
            NSApp.keyWindow?.makeFirstResponder(nil)
            quickLookURL = url
            fullSizeError = nil
        } catch {
            // Present the thumbnail we already have rather than an alert.
            if let image, let url = try? MediaFileHelper.writeThumbnailToTemporaryFile(image, for: download) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                quickLookURL = url
                fullSizeError = error.localizedDescription
            } else {
                errorReporter.report(.mediaPreviewFailed(filename: download.filename, reason: error.localizedDescription))
            }
        }
    }

    private func saveImage() async {
        guard let download else { return }
        do {
            try await MediaFileHelper.saveToFile(
                download: download, client: client,
                contentTypes: [.image]
            )
        } catch {
            errorReporter.report(.mediaSaveFailed(filename: download.filename, reason: error.localizedDescription))
        }
    }
}
