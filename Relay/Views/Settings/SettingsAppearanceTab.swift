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

import SwiftUI

/// The Appearance tab of the Settings window, providing a visual picker for
/// message bubble styles (grey vs. colored), styled after Apple's System Settings
/// appearance picker.
struct SettingsAppearanceTab: View {
    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Spacer()
                    BubbleStyleOption(
                        title: "Grey",
                        isSelected: !coloredBubbles,
                        content: { GreyBubblePreview() }
                    ) {
                        coloredBubbles = false
                    }

                    BubbleStyleOption(
                        title: "Colored",
                        isSelected: coloredBubbles,
                        content: { ColoredBubblePreview() }
                    ) {
                        coloredBubbles = true
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("Message Bubbles")
                Text("Choose how incoming messages appear in the timeline.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Bubble Style Option

/// A selectable thumbnail option in the Appearance settings, styled after Apple's
/// Appearance picker in System Settings.
private struct BubbleStyleOption<Content: View>: View {
    let title: String
    let isSelected: Bool
    @ViewBuilder var content: Content
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                content
                    .frame(width: 140, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    }
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bubble Previews

/// Miniature chat preview showing grey (default) incoming bubbles.
private struct GreyBubblePreview: View {
    var body: some View {
        ZStack {
            Color(.windowBackgroundColor)

            VStack(alignment: .leading, spacing: 3) {
                MiniOutgoingBubble(text: "How's it going?")
                MiniIncomingBubble(
                    text: "Pretty good!",
                    color: Color(.systemGray).opacity(0.25),
                    whiteText: false
                )
                MiniIncomingBubble(
                    text: "You?",
                    color: Color(.systemGray).opacity(0.25),
                    whiteText: false
                )
                MiniOutgoingBubble(text: "Great!")
            }
            .padding(8)
        }
    }
}

/// Miniature chat preview showing colored incoming bubbles.
private struct ColoredBubblePreview: View {
    var body: some View {
        ZStack {
            Color(.windowBackgroundColor)

            VStack(alignment: .leading, spacing: 3) {
                MiniOutgoingBubble(text: "How's it going?")
                MiniIncomingBubble(
                    text: "Pretty good!",
                    color: StableNameColor.color(for: "@alice:matrix.org")
                )
                MiniIncomingBubble(
                    text: "You?",
                    color: StableNameColor.color(for: "@bob:matrix.org")
                )
                MiniOutgoingBubble(text: "Great!")
            }
            .padding(8)
        }
    }
}

/// A tiny outgoing (right-aligned, accent-colored) bubble for the settings preview.
private struct MiniOutgoingBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 8))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule())
        }
    }
}

/// A tiny incoming (left-aligned) bubble for the settings preview.
private struct MiniIncomingBubble: View {
    let text: String
    let color: Color
    var whiteText = true

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 8))
                .foregroundStyle(whiteText ? .white : .primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color, in: Capsule())
            Spacer()
        }
    }
}

#Preview {
    TabView {
        SettingsAppearanceTab()
            .tabItem { Label("Appearance", systemImage: "paintbrush") }
    }
    .frame(width: 480)
}
