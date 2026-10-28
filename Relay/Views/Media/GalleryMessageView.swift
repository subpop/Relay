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
import SwiftUI

/// Renders a gallery message (MSC4274): images and videos as a slightly
/// fanned stack of cards above the bubble that you drag to flip through,
/// and a bubble below holding audio and file items as compact rows and the
/// shared caption. The bubble sizes to its own content, not the deck's. Each item behaves like its single-item view
/// (tap-to-reveal, QuickLook, download).
struct GalleryMessageView: View {
    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false

    let message: ObservableTimelineEvent
    let caption: String
    let items: [GalleryItem]
    let isOutgoing: Bool

    /// Upload progress (0 to 1) while the gallery is still being sent.
    var uploadProgress: Double? = nil

    @State private var deck = GalleryDeck()
    /// The deck as it was when the current drag began, nil when idle.
    @State private var dragStartDeck: GalleryDeck?
    /// Horizontal displacement of the top card within the current flip.
    @State private var dragOffset: CGFloat = 0

    private static let cardSize: CGFloat = 220
    /// Room around the cards for the fan.
    private static let fanMargin: CGFloat = 24
    /// Drag distance that flips one card.
    private static let flipDistance: CGFloat = 80

    private static var width: CGFloat { cardSize + fanMargin * 2 }

    private var style: BubbleStyle {
        .message(
            isOutgoing: isOutgoing,
            senderID: message.sender.value,
            coloredBubbles: coloredBubbles)
    }

    private var visualItems: [GalleryItem] {
        items.filter { $0.itemtype == .image || $0.itemtype == .video }
    }

    private var otherItems: [GalleryItem] {
        items.filter { $0.itemtype != .image && $0.itemtype != .video }
    }

    /// The caption to show, or nil when it's only the placeholder summary
    /// sent for galleries without text.
    private var visibleCaption: String? {
        caption.isEmpty || caption == GallerySummary.text(for: items.count) ? nil : caption
    }

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            if !visualItems.isEmpty {
                VStack {
                    cardStack
                    if visualItems.count > 1 {
                        stackControls
                    }
                }
                .frame(width: Self.width)
            }

            if !otherItems.isEmpty || visibleCaption != nil {
                bubble
            }
        }
    }

    // MARK: - Bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(otherItems.enumerated(), id: \.offset) { _, item in
                row(for: item)
            }

            if let visibleCaption {
                Text(visibleCaption)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .foregroundStyle(style.usesWhiteText ? .white : .primary)
            }
        }
        .background(style.backgroundColor)
        .clipShape(BubbleStyle.shape)
    }

    // MARK: - Card Stack

    private var cardStack: some View {
        let count = visualItems.count
        return ZStack {
            ForEach(deck.drawOrder(count: count), id: \.self) { index in
                card(for: visualItems[index], position: deck.position(of: index, count: count))
            }
        }
        .frame(width: Self.width, height: Self.cardSize + Self.fanMargin)
        .gesture(flipGesture(count: count))
        .overlay(alignment: .bottom) {
            if let uploadProgress {
                ProgressView(value: uploadProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                    .accessibilityLabel("Uploading attachments")
            }
        }
    }

    private func card(for item: GalleryItem, position: Int) -> some View {
        let isTop = position == 0
        return tile(for: item)
            // Opaque backing so cards behind don't show through placeholders.
            .background(.background)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(radius: 2)
            .scaleEffect(GalleryDeck.scale(forPosition: position))
            .rotationEffect(
                .degrees(GalleryDeck.angle(forPosition: position) + (isTop ? dragOffset / 20 : 0))
            )
            .offset(x: GalleryDeck.offset(forPosition: position) + (isTop ? dragOffset : 0))
            .allowsHitTesting(isTop)
            .animation(.spring, value: deck)
    }

    /// Flips through the deck as you drag: every `flipDistance` points
    /// moves one card, and the top card follows the remainder. Dragging
    /// left flips forward, right flips back. Releasing snaps to the
    /// nearest card.
    private func flipGesture(count: Int) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let start = dragStartDeck ?? deck
                dragStartDeck = start
                let steps = Int((-value.translation.width / Self.flipDistance).rounded(.towardZero))
                deck = start.moved(by: steps, count: count)
                dragOffset = value.translation.width + CGFloat(steps) * Self.flipDistance
            }
            .onEnded { value in
                let start = dragStartDeck ?? deck
                let steps = Int((-value.translation.width / Self.flipDistance).rounded())
                withAnimation(.spring) {
                    deck = start.moved(by: steps, count: count)
                    dragOffset = 0
                }
                dragStartDeck = nil
            }
    }

    private var stackControls: some View {
        HStack {
            Button("Previous", systemImage: "chevron.left") {
                withAnimation(.spring) { deck.retreat(count: visualItems.count) }
            }
            Text("\(deck.number(count: visualItems.count)) of \(visualItems.count)")
                .font(.caption)
                .monospacedDigit()
            Button("Next", systemImage: "chevron.right") {
                withAnimation(.spring) { deck.advance(count: visualItems.count) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Items

    @ViewBuilder
    private func tile(for item: GalleryItem) -> some View {
        let mediaItem = MediaItem(galleryItem: item)
        if item.itemtype == .video {
            VideoMessageView(item: mediaItem, tileSize: Self.cardSize)
        } else {
            ImageMessageView(item: mediaItem, tileSize: Self.cardSize)
        }
    }

    @ViewBuilder
    private func row(for item: GalleryItem) -> some View {
        let mediaItem = MediaItem(galleryItem: item)
        if item.itemtype == .audio {
            AudioMessageView(
                item: mediaItem, senderID: message.sender.value, isOutgoing: isOutgoing)
        } else {
            FileMessageView(
                item: mediaItem, senderID: message.sender.value, isOutgoing: isOutgoing)
        }
    }
}
