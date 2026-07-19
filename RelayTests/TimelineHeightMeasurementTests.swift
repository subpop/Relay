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
import Testing

@testable import Relay

// MARK: - Timeline Height / Clipping Measurement Tests
//
// These are headless regression guards for timeline message clipping — the
// class of bug where a message row is allotted slightly less height than its
// content actually draws, so the bottom/top gets cut off. They need no
// homeserver: they reconstruct the exact TextKit layout `MessageTextContent`
// uses and assert the content fits within the height the timeline measures.
//
// They cover three independent clipping causes:
//   1. Fractional container-width wrapping (MessageTextView.sizeThatFits).
//   2. Mention-pill vertical overhang (PillTextAttachment.paddedBounds).
//   3. Link-preview card height determinism (LinkPreviewView + aspect cache).

@MainActor
struct TimelineHeightMeasurementTests {

    init() {
        // Several tests parse through MatrixHTMLParser/MessageTextScale.
        // This test target shares UserDefaults with the app (bundle_loader),
        // so a real, persisted text-zoom level from manual testing could
        // otherwise leak into a comparison here. Reset for hermeticity.
        UserDefaults.standard.removeObject(forKey: MessageTextScale.userDefaultsKey)
    }

    // MARK: - TextKit Layout Harness

    /// A faithful replica of the `NSTextView`/`NSLayoutManager`/`NSTextContainer`
    /// configuration `MessageTextView.makeNSView` builds, so height/geometry
    /// measured here matches what the app renders.
    private struct Layout {
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        let storage: NSTextStorage
        /// The ceil'd used-rect height — what `MessageTextView.sizeThatFits`
        /// reports and the timeline uses as the row's text height.
        let usedHeight: CGFloat
    }

    /// Lays out `attributed` at the given container width using the app's exact
    /// TextKit settings (`usesFontLeading = false`, `lineFragmentPadding = 0`).
    /// The width is floored to match the app's render-time container width
    /// (`MessageTextView.sizeThatFits` measures the wrapped case at
    /// `pw.rounded(.down)`).
    private func layout(_ attributed: NSAttributedString, width: CGFloat) -> Layout {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: width.rounded(.down), height: .greatestFiniteMagnitude)
        )
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let usedHeight = ceil(layoutManager.usedRect(for: container).height)
        return Layout(
            layoutManager: layoutManager, container: container,
            storage: storage, usedHeight: usedHeight
        )
    }

    /// The base font used for message text and pill sizing.
    private var baseFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize) }

    /// Builds a resolved (pill-substituted) attributed string exactly as
    /// `MessageBubbleContent` → `MessageTextView` would, for an incoming bubble.
    private func resolvedIncoming(_ source: NSAttributedString) -> NSAttributedString {
        MessageTextView.applyColorOverrides(
            source, foreground: .labelColor, linkColor: .linkColor,
            pillStyle: .messageDefault
        )
    }

    /// A source attributed string with a `matrix.to` user mention over `mentionText`
    /// at the very start, so the resulting pill lands on the first (and, when
    /// short, the last) line.
    private func mentionSource(
        mentionText: String = "Sample User",
        trailing: String = " sent a short message to the room"
    ) -> NSAttributedString {
        let full = mentionText + trailing
        let src = NSMutableAttributedString(
            string: full,
            attributes: [.font: baseFont]
        )
        src.addAttribute(
            .link,
            value: URL(string: "https://matrix.to/#/@sample:matrix.org")!,
            range: NSRange(location: 0, length: (mentionText as NSString).length)
        )
        return src
    }

    // MARK: - 1. Mention-pill line height (must not grow / poke above text)

    /// A line containing a mention pill must be no taller than the same line of
    /// plain text. `PillTextAttachment.paddedBounds` previously sized the pill to
    /// ~18pt — taller than the ~15.3pt font line box — which grew the pill's line
    /// fragment ~2pt, stretched the pill image, and pushed the pill's top flush
    /// against the bubble's inner top edge (reading as a clipped, tight top).
    /// Capping the attachment to the line box keeps a pill line the same height
    /// as a normal text line. (TextKit "grow-and-shift" keeps the pill inside the
    /// used rect either way, so line growth — not a draw-overhang — is the defect.)
    @Test func mentionPillDoesNotGrowLineHeight() {
        // The same short message on one line (600pt-wide container) as plain
        // text and with a leading mention pill.
        let plain = layout(
            NSAttributedString(string: "Sample User wrote something", attributes: [.font: baseFont]),
            width: 600
        )

        let resolved = resolvedIncoming(mentionSource(trailing: " wrote something"))
        let withPill = layout(resolved, width: 600)

        var foundPill = false
        resolved.enumerateAttribute(.attachment, in: NSRange(location: 0, length: resolved.length)) { value, _, _ in
            if value is PillTextAttachment { foundPill = true }
        }
        #expect(foundPill, "Expected the mention to be substituted with a PillTextAttachment")

        #expect(
            withPill.usedHeight <= plain.usedHeight + 0.5,
            "Pill line height \(withPill.usedHeight)pt exceeds plain-text line height \(plain.usedHeight)pt — the pill grows the line and pokes above surrounding text."
        )
    }

    /// Direct unit invariant: a pill's attachment bounds must fit inside the
    /// font line box (top ≤ ascender, bottom ≥ descender) so it can never
    /// overhang whatever line it lands on.
    @Test func pillAttachmentBoundsFitWithinFontLineBox() {
        let pill = PillTextAttachment(
            userId: "@sample:matrix.org", displayName: "Sample User",
            font: baseFont, style: .messageDefault
        )
        let dummyContainer = NSTextContainer(
            size: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        )
        let bounds = pill.attachmentBounds(
            for: dummyContainer, proposedLineFragment: .zero,
            glyphPosition: .zero, characterIndex: 0
        )
        // Baseline-relative, +y up: top = bounds.maxY, bottom = bounds.minY.
        #expect(
            bounds.maxY <= baseFont.ascender + 0.5,
            "Pill top \(bounds.maxY) exceeds font ascender \(baseFont.ascender) — overhangs the line box."
        )
        #expect(
            bounds.minY >= baseFont.descender - 0.5,
            "Pill bottom \(bounds.minY) is below font descender \(baseFont.descender) — overhangs the line box."
        )
    }

    /// A pill's rendered glyphs must scale with the surrounding font size. If the
    /// pill view is rendered at a fixed text style while its attachment bounds are
    /// sized for a larger font, TextKit upscales the small bitmap into the large
    /// bounds and the capsule reads as stretched/blurry — the defect that surfaces
    /// once the timeline text-zoom enlarges the message font.
    @Test func mentionPillContentScalesWithFontSize() {
        func renderedPixelHeight(fontSize: CGFloat) -> Int {
            let view = MentionPillView(
                displayName: "Sample User", style: .messageDefault, fontSize: fontSize
            )
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.cgImage?.height ?? 0
        }
        let small = renderedPixelHeight(fontSize: NSFont.systemFontSize)
        let large = renderedPixelHeight(fontSize: NSFont.systemFontSize * 2)
        #expect(small > 0 && large > 0, "Pill failed to render.")
        #expect(
            Double(large) > Double(small) * 1.6,
            "Pill render height barely grew (\(small)px → \(large)px): the glyphs are not drawn at the target font size, so the bitmap is upscaled into the font-sized bounds and reads as stretched."
        )
    }

    // MARK: - 2. Fractional-width wrapping determinism

    /// Text height must be measured at the same integral width the container is
    /// rendered at. Measuring at a fractional `pw` while the live container ends
    /// up at `floor(pw)` makes a boundary line wrap one extra line on screen that
    /// the measured height never accounted for — clipping the last line.
    ///
    /// Here we assert the measured height (at `floor(w)`) fully contains the text
    /// laid out at that same render width across a sweep of fractional widths.
    @Test func textHeightMeasuredAtRenderWidthAcrossFractionalWidths() {
        let body = "the quick brown fox jumps over the lazy dog again "
            + "and again to make this message wrap onto several lines"
        let attributed = NSAttributedString(matrixMarkdown: body)

        // Sweep sub-point widths around a plausible bubble content width.
        for tenths in 0..<60 {
            let width = 300.0 + CGFloat(tenths) / 10.0
            let laid = layout(attributed, width: width)
            // Re-layout at exactly the floored render width and confirm the
            // reported (floored) used height contains it — i.e. no extra wrap
            // beyond what was measured.
            let renderWidth = width.rounded(.down)
            laid.container.size = NSSize(width: renderWidth, height: .greatestFiniteMagnitude)
            laid.layoutManager.ensureLayout(for: laid.container)
            let renderHeight = ceil(laid.layoutManager.usedRect(for: laid.container).height)
            #expect(
                laid.usedHeight >= renderHeight,
                "At width \(width): measured \(laid.usedHeight)pt < rendered \(renderHeight)pt — last line clips."
            )
        }
    }

    // MARK: - 3. Re-measurement on resize (narrower width must grow height)

    /// After a window resize the timeline re-measures visible rows at the new
    /// width. A message that wraps must report a *taller* height at a narrower
    /// width — the regression guard for rows keeping their old (too-short)
    /// height after a resize and clipping the re-wrapped text.
    @Test func wrappingMessageHeightGrowsAsWidthShrinks() {
        let body = "the quick brown fox jumps over the lazy dog again and again "
            + "so that this message must wrap onto several lines when it is narrow"
        let attributed = NSAttributedString(matrixMarkdown: body)
        let wide = layout(attributed, width: 520).usedHeight
        let narrow = layout(attributed, width: 240).usedHeight
        #expect(
            narrow > wide,
            "Height at 240pt (\(narrow)pt) is not greater than at 520pt (\(wide)pt); a resize to a narrower width would keep the old, too-short height and clip the re-wrapped text."
        )
    }

    /// A fresh `NSHostingController` measures a wrapping row taller at a narrower
    /// width. The timeline reuses one measurement host for speed, but reusing it
    /// *across a width change* returns the previous width's height — an
    /// `NSHostingController` re-measures on a content change (why text-zoom works)
    /// but not on a bare proposal change. That is why the timeline discards its
    /// host before a full re-measure on window resize; this guards the primitive
    /// that fix relies on.
    @Test func measurementHostIsWidthSensitiveWhenFresh() {
        func measure(width: CGFloat) -> CGFloat {
            let host = NSHostingController(rootView: AnyView(
                Text("the quick brown fox jumps over the lazy dog again and again "
                    + "so that this message wraps onto several lines when it is narrow")
                    .frame(maxWidth: 500, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            ))
            host.sizingOptions = [.standardBounds]
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        #expect(
            measure(width: 180) > measure(width: 480),
            "A narrower width must yield a taller measured row."
        )
    }

    // MARK: - 3b. Safe-area-aware effective content width

    /// The ordinary case: the column is wider than the combined insets, so
    /// the effective width is simply the difference.
    @Test func effectiveContentWidthSubtractsSafeAreaInsets() {
        let width = TimelineTableViewController.effectiveContentWidth(
            columnWidth: 610, safeAreaInsets: NSEdgeInsets(top: 0, left: 170, bottom: 0, right: 0)
        )
        #expect(width == 440)
    }

    /// A narrow window with the overlay sidebar's safe-area inset open can
    /// drive the raw subtraction to zero or negative — the exact scenario
    /// this branch's root-cause fix targets. `effectiveContentWidth` itself
    /// reports the (possibly negative) raw value; callers are responsible
    /// for their own floor/skip behavior on top of it. This guards the
    /// primitive `heightOfRow`'s `max(1, ...)` floor and
    /// `scheduleRemeasureIfEffectiveWidthChanged`'s `> 1` skip guard both
    /// build on, so a regression in either caller's clamp shows up as this
    /// raw value going unexpectedly non-negative instead.
    @Test func effectiveContentWidthCanGoNonPositiveWhenInsetsExceedColumn() {
        let width = TimelineTableViewController.effectiveContentWidth(
            columnWidth: 150, safeAreaInsets: NSEdgeInsets(top: 0, left: 170, bottom: 0, right: 0)
        )
        #expect(width <= 0, "Expected a non-positive raw width when insets exceed the column, got \(width).")
    }

    /// Regression guard for the specific floor `heightOfRow` applies: a
    /// negative effective width must never reach the measurement host as
    /// anything less than 1pt.
    @Test func flooredEffectiveContentWidthNeverGoesBelowOnePoint() {
        let raw = TimelineTableViewController.effectiveContentWidth(
            columnWidth: 100, safeAreaInsets: NSEdgeInsets(top: 0, left: 170, bottom: 0, right: 0)
        )
        #expect(raw < 1)
        #expect(max(1, raw) == 1)
    }

    // MARK: - 4. Link-preview card height determinism

    /// A variable-height link card must derive its height synchronously from the
    /// shared card cache, so the detached measurement host (whose async image
    /// load never runs) computes the same card height the live cell renders.
    @Test func linkCardHeightIsDeterministicFromCache() {
        let url = URL(string: "https://example.com/deterministic-\(UUID().uuidString)")!

        // Unresolved: placeholder height.
        let placeholderHeight = measuredHeight(
            LinkPreviewView(url: url, isOutgoing: false, messageID: "m1"), width: 400
        )

        // Resolved wide banner: stable, independent of message/instance.
        LinkPreviewView.cardCache.set(.banner(aspect: 2.0), forKey: url)
        let resolvedA = measuredHeight(
            LinkPreviewView(url: url, isOutgoing: false, messageID: "m2"), width: 400
        )
        let resolvedB = measuredHeight(
            LinkPreviewView(url: url, isOutgoing: true, messageID: "m3"), width: 400
        )
        #expect(resolvedA == resolvedB, "Card height must not depend on the message/instance.")
        #expect(
            resolvedA != placeholderHeight,
            "Card height must reflect the resolved aspect ratio, not the pre-load placeholder."
        )

        // Portrait aspect yields a taller card — height is genuinely aspect-driven.
        let tallURL = URL(string: "https://example.com/tall-\(UUID().uuidString)")!
        LinkPreviewView.cardCache.set(.banner(aspect: 0.5), forKey: tallURL)
        let tall = measuredHeight(
            LinkPreviewView(url: tallURL, isOutgoing: false, messageID: "m4"), width: 400
        )
        #expect(tall > resolvedA, "A portrait image should yield a taller card than a wide one.")
    }

    /// An unavailable link resolves to a hidden (zero-height) card.
    @Test func unavailableLinkCardIsHidden() {
        let url = URL(string: "https://example.com/gone-\(UUID().uuidString)")!
        LinkPreviewView.cardCache.set(.unavailable, forKey: url)
        let height = measuredHeight(
            LinkPreviewView(url: url, isOutgoing: false, messageID: "m1"), width: 400
        )
        #expect(height <= 1, "An unavailable link preview must collapse to zero height, got \(height)pt.")
    }

    /// A compact (favicon/globe) card has a fixed, deterministic height distinct
    /// from a hidden card.
    @Test func compactLinkCardHeightIsFixed() {
        let url = URL(string: "https://example.com/compact-\(UUID().uuidString)")!
        LinkPreviewView.cardCache.set(.compact, forKey: url)
        let a = measuredHeight(
            LinkPreviewView(url: url, isOutgoing: false, messageID: "m1"), width: 400
        )
        let b = measuredHeight(
            LinkPreviewView(url: url, isOutgoing: true, messageID: "m2"), width: 400
        )
        #expect(a == b, "Compact card height must be deterministic.")
        #expect(a > 1, "Compact card must have a non-zero height.")
    }

    // MARK: - Hosting Measurement Helper

    /// The height a detached `NSHostingController` reports for `view` at `width`
    /// — the same measurement path `TimelineTableViewController` uses for row
    /// heights (its `measurementHost`).
    private func measuredHeight(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
