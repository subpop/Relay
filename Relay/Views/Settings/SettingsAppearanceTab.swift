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

/// The Appearance tab of the Settings window, providing visual pickers for
/// the app's color scheme (light, dark, or system) and message bubble styles
/// (grey vs. colored), styled after Apple's System Settings appearance picker.
struct SettingsAppearanceTab: View {
    @AppStorage("appearance.mode") private var appearanceMode: AppAppearance = .system
    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false
    @AppStorage("appearance.showUnreadCounts") private var showUnreadCounts = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Spacer()
                    ForEach(AppAppearance.allCases) { mode in
                        AppearanceOption(
                            mode: mode,
                            isSelected: appearanceMode == mode
                        ) {
                            appearanceMode = mode
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle(isOn: $showUnreadCounts) {
                    Text("Show Unread Notification Counts")
                    Text("Rows end with the total unread count instead of a plain dot. Narrow rows always show a dot, and both turn red for mentions and direct messages.")
                }
            } header: {
                Text("Room List")
            }

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

// MARK: - Appearance Option

/// A selectable mini-desktop thumbnail for one of the three appearance modes.
private struct AppearanceOption: View {
    let mode: AppAppearance
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                AppearanceThumbnail(mode: mode)
                    .clipShape(.rect(cornerRadius: 5))
                    .padding(2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                isSelected ? Color.accentColor : .clear,
                                lineWidth: 3
                            )
                    }

                Text(mode.label)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Appearance Thumbnail

/// A miniature macOS desktop scene used as a thumbnail for appearance mode selection.
///
/// Light and dark modes render a single desktop with gradient wallpaper and two
/// overlapping mini windows. The "Auto" mode renders a split thumbnail: left half
/// light, right half dark.
private struct AppearanceThumbnail: View {
    let mode: AppAppearance

    private static let thumbnailWidth: CGFloat = 90
    private static let thumbnailHeight: CGFloat = 64

    var body: some View {
        switch mode {
        case .light:
            singleVariant(isDark: false)
        case .dark:
            singleVariant(isDark: true)
        case .system:
            systemThumbnail
        }
    }

    private func singleVariant(isDark: Bool) -> some View {
        desktopScene(isDark: isDark)
            .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
    }

    /// Split thumbnail showing light on the left, dark on the right.
    private var systemThumbnail: some View {
        HStack(spacing: 0) {
            desktopScene(isDark: false)
                .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
                .clipped()
                .frame(width: Self.thumbnailWidth / 2, alignment: .leading)
                .clipped()

            desktopScene(isDark: true)
                .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
                .clipped()
                .frame(width: Self.thumbnailWidth / 2, alignment: .trailing)
                .clipped()
        }
    }

    /// A miniature desktop with wallpaper gradient and two overlapping windows.
    private func desktopScene(isDark: Bool) -> some View {
        let wallpaper = isDark
            ? LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.10, blue: 0.30),
                    Color(red: 0.08, green: 0.15, blue: 0.40),
                    Color(red: 0.05, green: 0.12, blue: 0.35),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            : LinearGradient(
                colors: [
                    Color(red: 0.35, green: 0.55, blue: 0.90),
                    Color(red: 0.40, green: 0.60, blue: 0.95),
                    Color(red: 0.30, green: 0.50, blue: 0.85),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )

        return ZStack {
            wallpaper

            miniWindow(isDark: isDark)
                .scaleEffect(0.85)
                .offset(x: -6, y: -4)

            miniWindow(isDark: isDark)
                .scaleEffect(0.85)
                .offset(x: 6, y: 4)
        }
    }

    /// A tiny window with a title bar containing traffic-light circles.
    private func miniWindow(isDark: Bool) -> some View {
        let background = isDark
            ? Color(white: 0.18)
            : Color(white: 0.96)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(background)

            HStack(spacing: 2) {
                Circle().fill(.red.opacity(0.85)).frame(width: 3.5, height: 3.5)
                Circle().fill(.yellow.opacity(0.85)).frame(width: 3.5, height: 3.5)
                Circle().fill(.green.opacity(0.85)).frame(width: 3.5, height: 3.5)
            }
            .padding(4)
        }
        .frame(width: 56, height: 40)
        .clipShape(.rect(cornerRadius: 4))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
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
                MiniOutgoingBubble(
                    text: "How's it going?",
                    color: Color(stableColorFor: "@me:matrix.org")
                )
                MiniIncomingBubble(
                    text: "Pretty good!",
                    color: Color(stableColorFor: "@alice:matrix.org")
                )
                MiniIncomingBubble(
                    text: "You?",
                    color: Color(stableColorFor: "@steve:matrix.org")
                )
                MiniOutgoingBubble(
                    text: "Great!",
                    color: Color(stableColorFor: "@me:matrix.org")
                )
            }
            .padding(8)
        }
    }
}

/// A tiny outgoing (right-aligned, accent-colored) bubble for the settings preview.
private struct MiniOutgoingBubble: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 8))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color, in: Capsule())
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
