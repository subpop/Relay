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

import LinkPresentation
import SwiftUI

// LPLinkMetadata is not marked Sendable by Apple, but it is effectively
// immutable once returned by LPMetadataProvider. This retroactive conformance
// allows it to cross the actor boundary from LinkMetadataCache back to the
// main-actor-isolated views.
extension LPLinkMetadata: @retroactive @unchecked Sendable {}

// MARK: - Metadata Cache

/// A global, thread-safe cache for fetched link metadata, preventing redundant
/// network requests when cells are reused during scrolling.
///
/// Uses a dedicated actor so that fetches run independently of the main actor
/// and concurrent requests for the same URL are coalesced into a single fetch.
actor LinkMetadataCache {
    static let shared = LinkMetadataCache()

    private var cache: [URL: LPLinkMetadata] = [:]
    private var inFlight: [URL: Task<LPLinkMetadata?, Never>] = [:]

    /// Returns cached metadata immediately, or fetches it asynchronously.
    func metadata(for url: URL) async -> LPLinkMetadata? {
        if let cached = cache[url] { return cached }

        // Coalesce concurrent requests for the same URL.
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<LPLinkMetadata?, Never> {
            let provider = LPMetadataProvider()
            do {
                let metadata = try await provider.startFetchingMetadata(for: url)
                cache[url] = metadata
                return metadata
            } catch {
                return nil
            }
        }

        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }
}

// MARK: - LinkPreviewView

/// The fixed side length of the link preview card in points.
private let previewSize: CGFloat = 260

/// Displays a fixed-size link preview card for a URL.
///
/// The card has a constant size (`260×260` pt) so that loading metadata never
/// changes the row height. This eliminates the height-cache invalidation and
/// re-measurement that previously caused visible jumps during scrolling.
///
/// Metadata is fetched asynchronously via `LPMetadataProvider` and cached
/// globally so that scrolling through the timeline doesn't re-fetch.
struct LinkPreviewView: View {
    let url: URL
    let isOutgoing: Bool

    /// The timeline message ID that contains this preview.
    let messageID: String

    @State private var title: String?
    @State private var image: NSImage?
    @State private var didLoad = false
    @State private var didFail = false

    var body: some View {
        cardContent
            .frame(width: previewSize, height: previewSize)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
            .contentShape(.rect(cornerRadius: 12))
            .onTapGesture {
                NSWorkspace.shared.open(url)
            }
            .task(id: url) {
                await loadMetadata()
            }
    }

    @ViewBuilder
    private var cardContent: some View {
        if didFail {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                // Image area — fills the top portion.
                imageArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                // Text area — fixed at the bottom.
                textArea
            }
            .background(.fill.tertiary)
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else if !didLoad {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private var textArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? url.host() ?? url.absoluteString)
                .font(.callout)
                .bold()
                .lineLimit(2)
                .truncationMode(.tail)

            Text(url.host() ?? url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func loadMetadata() async {
        guard let metadata = await LinkMetadataCache.shared.metadata(for: url) else {
            didFail = true
            return
        }

        title = metadata.title

        // Extract the preview image from the metadata provider.
        if let imageProvider = metadata.imageProvider ?? metadata.iconProvider {
            image = await loadImage(from: imageProvider)
        }

        didLoad = true
    }

    private func loadImage(from provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
    }
}

// MARK: - Previews

#Preview("Link Preview") {
    VStack(spacing: 12) {
        LinkPreviewView(
            url: URL(string: "https://www.apple.com")!,
            isOutgoing: false,
            messageID: "preview-1"
        )

        LinkPreviewView(
            url: URL(string: "https://matrix.org")!,
            isOutgoing: true,
            messageID: "preview-2"
        )
    }
    .padding()
}
