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

extension Notification.Name {
    /// Posted when a ``LinkPreviewView`` finishes loading metadata and its
    /// intrinsic height changes. The `userInfo` dictionary contains a
    /// `"messageID"` string identifying the timeline row that needs
    /// re-measurement.
    static let linkPreviewDidLoad = Notification.Name("relay.linkPreviewDidLoad")
}

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

/// Displays a rich link preview card for a URL using the system `LPLinkView`.
///
/// Metadata is fetched asynchronously via `LPMetadataProvider` and cached globally
/// so that scrolling through the timeline doesn't re-fetch.
struct LinkPreviewView: View {
    let url: URL
    let isOutgoing: Bool

    /// The timeline message ID that contains this preview. Used to notify the
    /// table view controller that the row height needs re-measurement after
    /// metadata loads asynchronously.
    let messageID: String

    @State private var metadata: LPLinkMetadata?
    @State private var didFail = false

    var body: some View {
        Group {
            if let metadata {
                LinkPreviewRepresentable(metadata: metadata)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !didFail {
                // Subtle loading placeholder while metadata is in flight.
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
        .task(id: url) {
            if let fetched = await LinkMetadataCache.shared.metadata(for: url) {
                metadata = fetched
                // The row was initially measured while the preview was in its
                // loading state (small spinner). Now that the full LPLinkView
                // will render, post a notification so the table view controller
                // can invalidate the cached height and re-measure the row.
                NotificationCenter.default.post(
                    name: .linkPreviewDidLoad,
                    object: nil,
                    userInfo: ["messageID": messageID]
                )
            } else {
                didFail = true
            }
        }
    }
}

// MARK: - NSViewRepresentable

/// Wraps `LPLinkView` for use in SwiftUI on macOS.
private struct LinkPreviewRepresentable: NSViewRepresentable {
    let metadata: LPLinkMetadata

    func makeNSView(context: Context) -> LPLinkView {
        let view = LPLinkView(metadata: metadata)
        // Prevent the link view from expanding unboundedly.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: LPLinkView, context: Context) {
        nsView.metadata = metadata
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
        .frame(width: 300)
        .padding()
        .background(Color(.systemGray).opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))

        LinkPreviewView(
            url: URL(string: "https://matrix.org")!,
            isOutgoing: true,
            messageID: "preview-2"
        )
        .frame(width: 300)
        .padding()
        .background(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
    .padding()
}
