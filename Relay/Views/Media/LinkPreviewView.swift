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

// MARK: - Card Cache

/// The resolved presentation of a link preview, cached per URL.
///
/// Modelled as a type rather than a sentinel number so the loading, hidden, and
/// resolved states are explicit. A cache *miss* (no entry) means "not resolved
/// yet" — the card shows a placeholder.
enum LinkPreviewCard: Sendable, Equatable {
    /// The link has no usable preview; the card is hidden entirely.
    case unavailable
    /// A full-bleed Open-Graph image with the given aspect ratio (width ÷ height).
    case banner(aspect: CGFloat)
    /// A compact card (favicon or globe fallback) with a fixed image height.
    case compact
}

// MARK: - LinkPreviewView

/// Displays a link preview card sized to its Open-Graph image's aspect ratio.
///
/// The card width is fixed; the image height follows the loaded image's aspect
/// ratio (clamped to a sane range), so wide banners are shown edge-to-edge
/// without cropping. Links without a banner image fall back to a compact card
/// showing the site's favicon. Because the height is variable, the card triggers
/// a one-time row re-measure (via ``TimelineActions/remeasureRow``) when its
/// presentation resolves. Both the live cell and the timeline's detached
/// height-measurement host read the resolved card from ``cardCache`` so
/// measured and rendered heights match.
struct LinkPreviewView: View {
    let url: URL
    let isOutgoing: Bool

    /// The timeline message ID that contains this preview. Used to request a
    /// row re-measure once the card's presentation is known.
    let messageID: String

    @Environment(\.timelineActions) private var actions

    @State private var title: String?
    @State private var image: NSImage?

    /// This instance's resolved card, mirroring ``cardCache``.
    /// `nil` before resolution (placeholder / loading).
    @State private var card: LinkPreviewCard?

    /// A bounded cache of resolved link-preview presentations, keyed by URL.
    ///
    /// This is the linchpin that lets link-preview cards be **variable height**
    /// (sized to their image, iMessage-style) without the timeline clipping them.
    /// Row heights in ``TimelineTableViewController`` are measured by a *detached*
    /// `NSHostingController` whose SwiftUI `.task` never runs, so it cannot observe
    /// a per-view `@State` image loaded asynchronously. By publishing the resolved
    /// card here, both the live cell **and** the detached measurement host compute
    /// the identical card height synchronously at body-evaluation time — the
    /// measurement host renders a placeholder glyph at the *same* frame size the
    /// live cell renders the real image at, so measured and rendered heights agree.
    ///
    /// Backed by an LRU (``ParseCache``) so a long session browsing many links
    /// does not grow the cache without bound.
    static let cardCache = ParseCache<URL, LinkPreviewCard>(capacity: 256)

    /// Fixed card width in points. Only the image height varies.
    private static let cardWidth: CGFloat = 260
    /// Image height shown before the card resolves.
    private static let placeholderImageHeight: CGFloat = 150
    /// Clamp so extreme aspect ratios don't produce absurdly short/tall cards.
    private static let minImageHeight: CGFloat = 90
    private static let maxImageHeight: CGFloat = 340
    /// Compact image height for links with no Open-Graph banner (favicon/globe).
    private static let iconImageHeight: CGFloat = 72
    /// Maximum favicon edge within the compact card. Small favicons are drawn at
    /// their native size rather than upscaled to this.
    private static let faviconMaxSize: CGFloat = 40

    /// The card resolved for this URL: this instance's state, falling back to
    /// the shared cache so a freshly-built view (including the detached
    /// measurement host) sizes correctly without waiting for its `.task`.
    private var resolvedCard: LinkPreviewCard? {
        card ?? Self.cardCache.peek(url)
    }

    /// Whether the link has no usable preview and the card should be hidden.
    private var isHidden: Bool { resolvedCard == .unavailable }

    /// Whether this is a compact (favicon/globe) card rather than a banner.
    private var isCompact: Bool { resolvedCard == .compact }

    /// The image area height, derived from the resolved card.
    private var imageHeight: CGFloat {
        switch resolvedCard {
        case .banner(let aspect) where aspect > 0:
            return min(max(Self.cardWidth / aspect, Self.minImageHeight), Self.maxImageHeight)
        case .compact:
            return Self.iconImageHeight
        default:
            return Self.placeholderImageHeight
        }
    }

    var body: some View {
        Group {
            if isHidden {
                EmptyView()
            } else {
                cardBody
            }
        }
        .task(id: url) {
            // Seed from the cache so recycled/measurement instances size
            // correctly immediately, then (re)load for display.
            card = Self.cardCache.peek(url)
            await loadMetadata()
        }
    }

    private var cardBody: some View {
        VStack(spacing: 0) {
            imageArea
                .frame(width: Self.cardWidth, height: imageHeight)
                .clipped()

            textArea
        }
        .frame(width: Self.cardWidth)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        if let image {
            if isCompact {
                // Favicon: fit within the compact area rather than filling, so a
                // small square icon isn't cropped or stretched.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    // Never upscale a small favicon (e.g. 16×16): cap the fit
                    // frame at the icon's native size and at faviconMaxSize.
                    .frame(
                        maxWidth: min(image.size.width, Self.faviconMaxSize),
                        maxHeight: min(image.size.height, Self.faviconMaxSize)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        } else if resolvedCard == nil {
            ProgressView()
                .controlSize(.small)
        } else {
            // Compact card with no favicon available.
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private var textArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Reserve two lines regardless of the actual title length so the
            // text area height is deterministic — the detached measurement
            // host (which has no title yet) reserves the same space the live
            // cell uses for a wrapped two-line title.
            Text(title ?? url.host() ?? url.absoluteString)
                .font(.callout)
                .bold()
                .lineLimit(2, reservesSpace: true)
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
            resolve(.unavailable)
            return
        }

        title = metadata.title

        // A real Open-Graph image drives a full-bleed banner card. Otherwise fall
        // back to a compact card showing the favicon (or a globe if none). Only
        // fall back to the favicon when no banner image was offered at all —
        // not merely because the offered one failed to load or decoded to a
        // degenerate size — so a page can't force a second, potentially
        // different-origin fetch just by serving a broken `og:image`.
        if let imageProvider = metadata.imageProvider {
            if let loaded = await loadImage(from: imageProvider),
               loaded.size.width > 0, loaded.size.height > 0 {
                image = loaded
                resolve(.banner(aspect: loaded.size.width / loaded.size.height))
            } else {
                image = nil
                resolve(.compact)
            }
        } else if let iconProvider = metadata.iconProvider,
                  let icon = await loadImage(from: iconProvider),
                  icon.size.width > 0, icon.size.height > 0 {
            image = icon
            resolve(.compact)
        } else {
            image = nil
            resolve(.compact)
        }
    }

    /// Publishes the resolved card to the shared cache and this instance, and
    /// re-measures the row when the resolved *height* can change.
    private func resolve(_ resolved: LinkPreviewCard) {
        // Compare against this instance's own prior state, not the shared,
        // URL-keyed cache: two rows referencing the same URL both resolve
        // independently, and the cache's previous value may already have
        // been overwritten by a sibling row's resolution — comparing against
        // it would skip this row's own placeholder-to-final remeasure.
        let instancePrevious = card
        Self.cardCache.set(resolved, forKey: url)
        card = resolved
        // Re-measure on any height-changing transition: the first resolution, a
        // compact fallback upgrading to a banner (e.g. after a transient
        // image-load failure), or a changed banner aspect. Re-resolving to the
        // same card — including a globe→favicon swap, which keeps the compact
        // height — needs no re-measure.
        if instancePrevious != resolved {
            actions.remeasureRow?(messageID)
        }
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
