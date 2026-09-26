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

/// An avatar that displays a user's or room's profile image, falling back to colored initials.
///
/// When an `mxcURL` is provided, the view asynchronously loads a thumbnail from the Matrix
/// homeserver. If no URL is available or the download fails, a deterministic colored shape
/// with the entity's initials is shown instead.
///
/// By default the avatar clips to a circle. Pass a custom `shape` to use a different
/// clip shape (e.g. a rounded rectangle for space avatars).
struct AvatarView: View {
    @Environment(RelayClient.self) private var client

    /// The display name used to generate initials. Also used for the fallback
    /// background color when ``colorID`` is `nil`.
    let name: String

    /// The `mxc://` URL for the avatar image, or `nil` to always show initials.
    let mxcURL: String?

    /// The diameter of the avatar in points.
    let size: CGFloat

    /// A stable identifier (e.g. a Matrix user ID) used to derive the fallback
    /// background color. When `nil`, the ``name`` is used instead. Pass a user
    /// ID here so that the avatar's color matches other UI elements (like message
    /// bubbles) that derive color from the same identifier.
    var colorID: String?

    /// The clip shape applied to the avatar. Defaults to a circle.
    var shape: AnyShape = AnyShape(Circle())

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: mxcURL) {
            // Clear any stale image immediately when the URL changes (e.g. switching
            // rooms in the toolbar capsule). Doing this here instead of a separate
            // onChange(of: name) avoids a race where the onChange fires *after* a
            // cache-hit sets the image, wiping it back to nil.
            image = nil

            guard let mxcURL else { return }
            image = await client.avatarThumbnail(mxcURL: mxcURL, size: size)
        }
    }

    private var initialsView: some View {
        ZStack {
            shape
                .fill(color(for: name))

            Text(initials(for: name))
                .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private func initials(for name: String) -> String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func color(for name: String) -> Color {
        Color(stableColorFor: colorID ?? name)
    }
}

// MARK: - Avatar badges

/// Shared badge content for avatar corners.
///
/// Factories take explicit colors so each call site keeps its own palette
/// (sidebar indicators use non-vibrant `systemRed`/`systemBlue`/`systemGray`
/// so they render opaque in the sidebar; settings and inspector badges keep
/// their tint/accent fills).
enum AvatarBadge {
    /// One of the four avatar corners a badge can occupy.
    enum Corner {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        /// The matching frame alignment for the corner.
        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
    }

    /// A numbered capsule, e.g. an unread-mention count.
    static func count(_ count: Int, color: Color) -> some View {
        Text(count, format: .number)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(color, in: .capsule)
    }

    /// A bare dot, e.g. a plain-unread indicator.
    static func dot(color: Color, diameter: CGFloat = 8) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
    }
}

extension View {
    /// Pins a badge to one corner of an avatar, centered on the avatar's
    /// corner arc (the 45° point of its circular edge) so the badge
    /// straddles the edge identically at every avatar and badge size.
    ///
    /// Composes like `overlay`: chain one call per corner and each corner
    /// keeps a single badge. Placement shifts through alignment guides, so
    /// hit areas follow the badge, and never grows the surrounding layout.
    func badge(at corner: AvatarBadge.Corner = .bottomTrailing, @ViewBuilder content: () -> some View) -> some View {
        CornerBadge(corner: corner, host: self, badge: content())
    }

    /// Styles an icon as a filled badge circle of the given diameter.
    ///
    /// Keeps the caller's font (including Dynamic Type text styles) and
    /// only unifies the sizing and fill shared by every avatar badge icon.
    func badgeIcon<S: ShapeStyle>(fill: S, diameter: CGFloat) -> some View {
        frame(width: diameter, height: diameter)
            .background(fill, in: .circle)
    }
}

/// Places a badge over one corner of the wrapped host, centered on the
/// host's corner arc so the badge straddles the edge regardless of avatar
/// or badge size.
private struct CornerBadge<Host: View, Badge: View>: View {
    let corner: AvatarBadge.Corner
    let host: Host
    let badge: Badge

    @State private var hostSize: CGSize = .zero

    var body: some View {
        ZStack {
            host
                .onGeometryChange(for: CGSize.self) { $0.size } action: { hostSize = $0 }
            if hostSize != .zero {
                guided(badge)
                    .frame(width: hostSize.width, height: hostSize.height, alignment: corner.alignment)
            }
        }
    }

    /// Overrides the badge's corner alignment guides to center it on the
    /// corner arc. Positive insets move the badge toward the host's
    /// center; negative values let oversized badges poke outward.
    @ViewBuilder
    private func guided(_ badge: Badge) -> some View {
        let inset = arcInset
        switch corner {
        case .topLeading:
            badge
                .alignmentGuide(.leading) { $0[.leading] - CornerArc.centeringInset(arcInset: inset, extent: $0.width) }
                .alignmentGuide(.top) { $0[.top] - CornerArc.centeringInset(arcInset: inset, extent: $0.height) }
        case .topTrailing:
            badge
                .alignmentGuide(.trailing) { $0[.trailing] + CornerArc.centeringInset(arcInset: inset, extent: $0.width) }
                .alignmentGuide(.top) { $0[.top] - CornerArc.centeringInset(arcInset: inset, extent: $0.height) }
        case .bottomLeading:
            badge
                .alignmentGuide(.leading) { $0[.leading] - CornerArc.centeringInset(arcInset: inset, extent: $0.width) }
                .alignmentGuide(.bottom) { $0[.bottom] + CornerArc.centeringInset(arcInset: inset, extent: $0.height) }
        case .bottomTrailing:
            badge
                .alignmentGuide(.trailing) { $0[.trailing] + CornerArc.centeringInset(arcInset: inset, extent: $0.width) }
                .alignmentGuide(.bottom) { $0[.bottom] + CornerArc.centeringInset(arcInset: inset, extent: $0.height) }
        }
    }

    /// Inset of a circular avatar's corner-arc point from its edges — the
    /// 45° point where a badge straddles the edge.
    private var arcInset: CGFloat {
        CornerArc.inset(for: hostSize)
    }
}

/// Corner-arc geometry for badge placement.
///
/// Lives outside the view so the nonisolated alignment-guide closures can
/// call it without capturing the view.
private nonisolated enum CornerArc {
    /// Inset of a circular host's corner-arc point from its edges.
    static func inset(for size: CGSize) -> CGFloat {
        min(size.width, size.height) * (1 - 1 / sqrt(2)) / 2
    }

    /// Nudge toward the host's center that centers a badge of the given
    /// extent on the corner arc. Negative values nudge outward, so
    /// oversized badges still straddle the edge.
    static func centeringInset(arcInset: CGFloat, extent: CGFloat) -> CGFloat {
        arcInset - extent / 2
    }
}

#Preview("Initials") {
    HStack(spacing: 16) {
        AvatarView(name: "Alice Smith", mxcURL: nil, size: 48)
        AvatarView(name: "Bob", mxcURL: nil, size: 36)
        AvatarView(name: "Charlie Davis", mxcURL: nil, size: 28)
    }
    .padding()
}

#Preview("Sizes") {
    VStack(spacing: 12) {
        AvatarView(name: "Relay User", mxcURL: nil, size: 64)
        AvatarView(name: "Relay User", mxcURL: nil, size: 36)
        AvatarView(name: "Relay User", mxcURL: nil, size: 24)
    }
    .padding()
}
