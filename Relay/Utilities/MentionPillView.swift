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
}

/// A capsule-shaped pill view for inline mention display.
///
/// ``MentionPillView`` is rendered to a static `NSImage` by ``PillTextAttachment``
/// at creation time. The image is set on the attachment and displayed inline by
/// the `NSTextView`'s layout system. It displays `@DisplayName` in a rounded
/// capsule styled according to its ``MentionPillStyle``.
struct MentionPillView: View {
    let displayName: String

    /// The user's stable color derived from ``StableNameColor``.
    /// Used as the pill's capsule background tint in `.compose` and `.messageDefault` styles.
    var tintColor: Color = .accentColor

    /// The visual style of the pill. Defaults to `.compose`.
    var style: MentionPillStyle = .compose

    private var pillText: String {
        displayName.hasPrefix("@") ? displayName : "@\(displayName)"
    }

    private var textColor: Color {
        switch style {
        case .compose, .messageDefault:
            .primary
        case .messageWhiteText:
            .white
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .compose:
            tintColor.opacity(0.3)
        case .messageDefault:
            tintColor.opacity(0.2)
        case .messageWhiteText:
            .white.opacity(0.3)
        }
    }

    var body: some View {
        Text(pillText)
            .font(.callout)
            .bold()
            .foregroundStyle(textColor)
            .padding(.horizontal, 4)
            .background(backgroundColor, in: .capsule)
    }

    // MARK: - Measurement

    /// Horizontal padding inside the capsule (leading + trailing).
    private static let horizontalPadding: CGFloat = 12

    /// Vertical padding inside the capsule (top + bottom).
    private static let verticalPadding: CGFloat = 1

    /// Measures the size the pill will occupy for layout purposes.
    static func measureSize(displayName: String, font: NSFont) -> CGSize {
        let label = displayName.hasPrefix("@") ? displayName : "@\(displayName)"
        let text = label as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: font.pointSize - 1, weight: .bold),
        ]
        let textSize = text.size(withAttributes: attributes)
        return CGSize(
            width: ceil(textSize.width + horizontalPadding),
            height: ceil(textSize.height + verticalPadding)
        )
    }
}

#Preview("Compose") {
    VStack(spacing: 12) {
        MentionPillView(
            displayName: "Alice Smith",
            tintColor: StableNameColor.color(for: "@alice:matrix.org"),
            style: .compose
        )
        MentionPillView(
            displayName: "Bob",
            tintColor: StableNameColor.color(for: "@bob:matrix.org"),
            style: .compose
        )
    }
    .padding()
}

#Preview("Default Incoming (Grey Bubble)") {
    VStack(spacing: 12) {
        MentionPillView(
            displayName: "Alice Smith",
            tintColor: StableNameColor.color(for: "@alice:matrix.org"),
            style: .messageDefault
        )
        MentionPillView(
            displayName: "Bob",
            tintColor: StableNameColor.color(for: "@bob:matrix.org"),
            style: .messageDefault
        )
    }
    .padding()
    .background(Color(.unemphasizedSelectedContentBackgroundColor))
}

#Preview("Outgoing Blue Bubble") {
    VStack(spacing: 12) {
        MentionPillView(displayName: "Alice Smith", style: .messageWhiteText)
        MentionPillView(displayName: "Bob", style: .messageWhiteText)
    }
    .padding()
    .background(Color.accentColor)
}

#Preview("Colored Bubble — Warm") {
    VStack(spacing: 12) {
        MentionPillView(displayName: "Alice Smith", style: .messageWhiteText)
        MentionPillView(displayName: "Bob", style: .messageWhiteText)
    }
    .padding()
    .background(StableNameColor.color(for: "@eve:matrix.org"))
}

#Preview("Colored Bubble — Cool") {
    VStack(spacing: 12) {
        MentionPillView(displayName: "Alice Smith", style: .messageWhiteText)
        MentionPillView(displayName: "Bob", style: .messageWhiteText)
    }
    .padding()
    .background(StableNameColor.color(for: "@frank:matrix.org"))
}
