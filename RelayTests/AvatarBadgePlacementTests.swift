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

// MARK: - Avatar Badge Placement Tests
//
// Headless regression guards for avatar badge placement. A badge centers
// on the avatar's corner arc — the 45° point of its circular edge — so
// every badge straddles the edge identically regardless of avatar or
// badge size. These render the badge chain offscreen and sample pixels,
// so a flipped alignment-guide sign or a misplaced arc center fails
// loudly without a homeserver or a window.

@MainActor
struct AvatarBadgePlacementTests {
    private typealias RGB = (red: Double, green: Double, blue: Double)

    /// A solid-color circle standing in for an avatar, with a solid-color
    /// circle badge in one corner.
    private struct Probe: View {
        var avatarSize: CGFloat
        var badgeSize: CGFloat
        var corner: AvatarBadge.Corner

        var body: some View {
            Circle()
                .fill(.green)
                .frame(width: avatarSize, height: avatarSize)
                .badge(at: corner) {
                    Circle()
                        .fill(.red)
                        .frame(width: badgeSize, height: badgeSize)
                }
                .background(.white)
                .frame(width: avatarSize, height: avatarSize)
        }
    }

    /// Renders a probe at 1x and returns its pixels with row 0 at the top.
    /// The first render settles the badge's geometry measurement; the
    /// second captures the placed badge.
    private func pixels(avatarSize: CGFloat, badgeSize: CGFloat, corner: AvatarBadge.Corner) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: Probe(
            avatarSize: avatarSize,
            badgeSize: badgeSize,
            corner: corner))
        renderer.scale = 1
        _ = renderer.nsImage
        guard let image = renderer.nsImage else { return nil }
        let side = Int(avatarSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The sampled color at a pixel, as 0–1 RGB.
    private func color(at x: Int, y: Int, in rep: NSBitmapImageRep) -> RGB? {
        guard let color = rep.colorAt(x: x, y: y) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return (Double(red), Double(green), Double(blue))
    }

    private func isRed(_ rgb: RGB?) -> Bool {
        guard let rgb else { return false }
        return rgb.red > 0.7 && rgb.green < 0.3 && rgb.blue < 0.3
    }

    private func isGreen(_ rgb: RGB?) -> Bool {
        guard let rgb else { return false }
        return rgb.green > 0.4 && rgb.green > rgb.red + 0.2 && rgb.green > rgb.blue + 0.2
    }

    private func isWhite(_ rgb: RGB?) -> Bool {
        guard let rgb else { return false }
        return rgb.red > 0.7 && rgb.green > 0.7 && rgb.blue > 0.7
    }

    /// Asserts one badge placement: red on the corner arc, avatar visible
    /// at its center, and the opposite corner clear (where a sign-flipped
    /// badge would land).
    private func assertStraddle(
        avatarSize: CGFloat,
        badgeSize: CGFloat,
        corner: AvatarBadge.Corner,
        arc: (x: Int, y: Int),
        opposite: (x: Int, y: Int),
        overhang: (x: Int, y: Int)? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let rep = pixels(avatarSize: avatarSize, badgeSize: badgeSize, corner: corner) else {
            Issue.record("render failed", sourceLocation: sourceLocation)
            return
        }
        let center = Int(avatarSize / 2)
        #expect(isRed(color(at: arc.x, y: arc.y, in: rep)), "badge center not on arc", sourceLocation: sourceLocation)
        #expect(isGreen(color(at: center, y: center, in: rep)), "avatar center not uncovered", sourceLocation: sourceLocation)
        #expect(isWhite(color(at: opposite.x, y: opposite.y, in: rep)), "opposite corner not clear", sourceLocation: sourceLocation)
        if let overhang {
            #expect(isRed(color(at: overhang.x, y: overhang.y, in: rep)), "badge does not overhang the edge", sourceLocation: sourceLocation)
        }
    }

    // 48pt avatar, 18pt badge: the room-list attention badge. Its inset is
    // negative, so the badge overhangs the avatar's edge.
    @Test func roomListAttentionStraddles() {
        assertStraddle(
            avatarSize: 48, badgeSize: 18, corner: .topTrailing,
            arc: (41, 7), opposite: (1, 46), overhang: (44, 4))
    }

    // 36pt avatar, 8pt dot: the space-rail unread dot, whose inset is
    // positive, so the dot sits inside the avatar's corner.
    @Test func spaceRailDotStraddles() {
        assertStraddle(
            avatarSize: 36, badgeSize: 8, corner: .topTrailing,
            arc: (31, 5), opposite: (1, 34))
    }

    // 80pt avatar, 22pt badge: the settings and inspector camera/trash
    // buttons.
    @Test func bottomTrailingStraddles() {
        assertStraddle(
            avatarSize: 80, badgeSize: 22, corner: .bottomTrailing,
            arc: (68, 68), opposite: (2, 2))
    }

    @Test func topLeadingStraddles() {
        assertStraddle(
            avatarSize: 80, badgeSize: 22, corner: .topLeading,
            arc: (12, 12), opposite: (78, 78))
    }

    @Test func bottomLeadingStraddles() {
        assertStraddle(
            avatarSize: 80, badgeSize: 22, corner: .bottomLeading,
            arc: (12, 68), opposite: (78, 2))
    }
}
