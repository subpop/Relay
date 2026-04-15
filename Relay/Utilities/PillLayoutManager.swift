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

// MARK: - Custom Attribute Key

extension NSAttributedString.Key {
    /// Custom attribute key for pill-shaped background color. Ranges carrying
    /// this attribute are drawn with a rounded capsule background by
    /// ``PillLayoutManager`` instead of the flat rectangle that
    /// `.backgroundColor` produces.
    static let mentionPillColor = NSAttributedString.Key("relay.mentionPillColor")
}

// MARK: - PillLayoutManager

/// An `NSLayoutManager` subclass that draws capsule-shaped (pill) backgrounds
/// behind text ranges marked with the `.mentionPillColor` attribute.
///
/// Standard `NSAttributedString.backgroundColor` renders as a flat rectangle.
/// This layout manager intercepts background drawing and replaces it with a
/// rounded rect for any range carrying `.mentionPillColor`, producing a pill
/// appearance with configurable horizontal/vertical padding (insets).
nonisolated final class PillLayoutManager: NSLayoutManager, @unchecked Sendable {

    /// Local reference to the pill attribute key, avoiding main-actor-isolated
    /// access from the nonisolated `drawBackground` override.
    private static let pillKey = NSAttributedString.Key("relay.mentionPillColor")

    /// Horizontal inset from the glyph rect edge. The pill-attributed range
    /// includes internal thin-space characters for padding; this inset pulls
    /// the capsule inward so those edge spaces sit outside the background,
    /// creating a visible gap from adjacent text.
    var pillHorizontalInset: CGFloat = 2

    /// Vertical expansion beyond the glyph rect for a taller capsule.
    var pillVerticalExpansion: CGFloat = 1

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Draw standard backgrounds first (e.g. inline code).
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let storage = textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(
            Self.pillKey,
            in: charRange,
            options: []
        ) { value, attrRange, _ in
            guard let color = value as? NSColor else { return }

            let pillGlyphRange = glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)

            // Tight bounding rect around the actual glyphs (includes internal
            // thin-space padding characters).
            let glyphRect = self.boundingRect(forGlyphRange: pillGlyphRange, in: container)

            // Use the line fragment used rect for vertical centering — it
            // represents the full line height and is properly positioned
            // within the text container.
            let lineUsedRect = self.lineFragmentUsedRect(
                forGlyphAt: pillGlyphRange.location, effectiveRange: nil
            )

            // Horizontally: inset from glyph rect so thin-space edges sit
            // outside the capsule. Vertically: use line used rect expanded
            // by pillVerticalExpansion, centered on the line.
            let capsuleHeight = lineUsedRect.height + self.pillVerticalExpansion * 2
            let capsuleY = lineUsedRect.midY - capsuleHeight / 2

            var pillRect = CGRect(
                x: glyphRect.origin.x + self.pillHorizontalInset,
                y: capsuleY,
                width: glyphRect.width - self.pillHorizontalInset * 2,
                height: capsuleHeight
            )
            pillRect = pillRect.offsetBy(dx: origin.x, dy: origin.y)

            let radius = pillRect.height / 2
            let path = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
            color.setFill()
            path.fill()
        }
    }
}
