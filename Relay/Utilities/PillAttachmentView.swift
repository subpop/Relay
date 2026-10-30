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

/// The visual style applied to a mention pill, determining text and background colors.
///
/// Each style is tuned for a specific bubble context so that the pill reads
/// clearly without looking like a pasted image:
///
/// - ``compose``: Compose text field — stable color tint on a dark surface.
/// - ``messageDefault``: Default incoming grey bubble — stable color tint with
///   primary label text. Works in both light and dark mode because the grey
///   backdrop is neutral.
/// - ``messageWhiteText``: Any bubble with white text (outgoing blue, or any
///   colored bubble) — translucent white fill with white text, giving a frosted
///   glass appearance that works on any saturated hue.
enum MentionPillStyle: Sendable {
    /// Compose bar — stable color tint, primary text.
    case compose

    /// Default incoming (grey bubble) — stable color tint, primary text.
    case messageDefault

    /// Outgoing blue bubble or any colored bubble — frosted white.
    case messageWhiteText

    /// A mention of the current user in a highlighted message — red
    /// background with white text to draw attention.
    case highlightedMention
}

/// An `NSView` that draws a mention pill: bold text in a rounded capsule.
///
/// ``PillTextAttachment`` hosts this view inline in TextKit 2 layouts via its
/// view provider, so the pill adapts to appearance changes without rebuilding
/// the attributed string. The pill is render-only — ``hitTest`` returns `nil`
/// so pointer events reach the enclosing text view, whose `.link` handling on
/// the attachment character provides clicks, hover, and navigation.
final class PillAttachmentView: NSView {

    private let label = NSTextField(labelWithString: "")
    private let fill: NSColor
    private let pillText: String
    private let measuredSize: NSSize

    init(displayName: String, userId: String, style: MentionPillStyle, prefixSigil: Character?, fontSize: CGFloat) {
        self.pillText = Self.pillText(displayName: displayName, prefixSigil: prefixSigil)
        self.fill = Self.fill(userId: userId, style: style)
        self.measuredSize = Self.measureSize(
            displayName: displayName,
            font: NSFont.systemFont(ofSize: fontSize),
            prefixSigil: prefixSigil
        )
        super.init(frame: .zero)
        label.stringValue = pillText
        label.font = .systemFont(ofSize: fontSize - 1, weight: .bold)
        label.textColor = Self.labelColor(for: style)
        addSubview(label)
        setAccessibilityLabel(pillText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PillAttachmentView does not support NSCoding")
    }

    // MARK: - Style Colors

    /// The label color for each style (see ``MentionPillStyle``).
    private static func labelColor(for style: MentionPillStyle) -> NSColor {
        switch style {
        case .compose, .messageDefault: .labelColor
        case .messageWhiteText, .highlightedMention: .white
        }
    }

    /// The capsule fill for each style. Tinted styles bake their alpha into
    /// the dynamic stable color (rather than calling `withAlphaComponent`,
    /// which would resolve and flatten it) so they keep adapting to
    /// appearance changes.
    private static func fill(userId: String, style: MentionPillStyle) -> NSColor {
        switch style {
        case .compose: NSColor(stableColorFor: userId, alpha: 0.3)
        case .messageDefault: NSColor(stableColorFor: userId, alpha: 0.2)
        case .messageWhiteText: .white.withAlphaComponent(0.3)
        case .highlightedMention: .systemRed
        }
    }

    // MARK: - Render-Only Behavior

    override var acceptsFirstResponder: Bool { false }

    /// The pill never handles pointer events; clicks fall through to the
    /// enclosing text view, which resolves the `.link` attribute on the
    /// attachment character.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize { measuredSize }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// TextKit 2 sizes the attachment view by setting its frame; re-center
    /// the label whenever that happens.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    /// The label color and capsule fill are dynamic `NSColor`s; redraw when
    /// the appearance flips so they re-resolve.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        label.needsDisplay = true
    }

    // MARK: - Measurement

    /// Horizontal padding inside the capsule (leading + trailing).
    private static let horizontalPadding: CGFloat = 12

    /// Vertical padding inside the capsule (top + bottom).
    private static let verticalPadding: CGFloat = 1

    /// Measures the size the pill will occupy for layout purposes.
    static func measureSize(displayName: String, font: NSFont, prefixSigil: Character? = "@") -> CGSize {
        let text = Self.pillText(displayName: displayName, prefixSigil: prefixSigil) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: font.pointSize - 1, weight: .bold),
        ]
        let textSize = text.size(withAttributes: attributes)
        return CGSize(
            width: ceil(textSize.width + horizontalPadding),
            height: ceil(textSize.height + verticalPadding)
        )
    }

    /// The text shown in the pill: the display name with the sigil prepended
    /// (`@` for a user mention, `#` for a room mention) unless it is already
    /// prefixed.
    private static func pillText(displayName: String, prefixSigil: Character?) -> String {
        guard let prefixSigil else { return displayName }
        return displayName.hasPrefix(String(prefixSigil)) ? displayName : "\(prefixSigil)\(displayName)"
    }
}

// MARK: - Previews

/// Hosts a ``PillAttachmentView`` at its intrinsic size.
private struct PillPreview: NSViewRepresentable {
    var displayName: String
    var userId: String
    var style: MentionPillStyle

    func makeNSView(context: Context) -> PillAttachmentView {
        PillAttachmentView(
            displayName: displayName, userId: userId, style: style,
            prefixSigil: "@", fontSize: NSFont.systemFontSize
        )
    }

    func updateNSView(_ nsView: PillAttachmentView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PillAttachmentView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

#Preview("Compose") {
    VStack(spacing: 12) {
        PillPreview(displayName: "Alice Smith", userId: "@alice:matrix.org", style: .compose)
        PillPreview(displayName: "Bob", userId: "@bob:matrix.org", style: .compose)
    }
    .padding()
}

#Preview("Default Incoming (Grey Bubble)") {
    VStack(spacing: 12) {
        PillPreview(displayName: "Alice Smith", userId: "@alice:matrix.org", style: .messageDefault)
        PillPreview(displayName: "Bob", userId: "@bob:matrix.org", style: .messageDefault)
    }
    .padding()
    .background(Color(.unemphasizedSelectedContentBackgroundColor))
}

#Preview("Outgoing Blue Bubble") {
    VStack(spacing: 12) {
        PillPreview(displayName: "Alice Smith", userId: "@alice:matrix.org", style: .messageWhiteText)
        PillPreview(displayName: "Bob", userId: "@bob:matrix.org", style: .messageWhiteText)
    }
    .padding()
    .background(Color.accentColor)
}

#Preview("Colored Bubble — Warm") {
    VStack(spacing: 12) {
        PillPreview(displayName: "Alice Smith", userId: "@alice:matrix.org", style: .messageWhiteText)
        PillPreview(displayName: "Bob", userId: "@bob:matrix.org", style: .messageWhiteText)
    }
    .padding()
    .background(Color(stableColorFor: "@eve:matrix.org"))
}

#Preview("Colored Bubble — Cool") {
    VStack(spacing: 12) {
        PillPreview(displayName: "Alice Smith", userId: "@alice:matrix.org", style: .messageWhiteText)
        PillPreview(displayName: "Bob", userId: "@bob:matrix.org", style: .messageWhiteText)
    }
    .padding()
    .background(Color(stableColorFor: "@frank:matrix.org"))
}
