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

extension NSColor {
    /// Creates the dynamic `NSColor` behind ``Color/init(stableColorFor:)``,
    /// with an alpha baked in.
    ///
    /// The alpha is applied inside the dynamic color's resolver rather than
    /// via `withAlphaComponent`, which would resolve and flatten the
    /// appearance-adaptive color into a fixed one.
    convenience init(stableColorFor name: String, alpha: CGFloat) {
        let hash = Color.djb2Hash(name)
        let hueDegrees = Double(hash % 360)

        self.init(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                // Dark mode: moderate lightness, slightly higher chroma.
                let (r, g, b) = Color.oklchToSRGB(L: 0.55, C: 0.12, H: hueDegrees)
                return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
            } else {
                // Light mode: higher lightness, gentler chroma.
                let (r, g, b) = Color.oklchToSRGB(L: 0.72, C: 0.11, H: hueDegrees)
                return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
            }
        }
    }
}

extension Color {
    /// Creates a deterministic, appearance-adaptive color derived from the given string
    /// (e.g. a Matrix user ID or display name).
    ///
    /// Uses the DJB2 hash algorithm to ensure colors are stable across app launches,
    /// unlike Swift's `hashValue` which is randomized per process. The resulting color
    /// is suitable for avatar backgrounds and message bubble fills with white text on top.
    ///
    /// Colors are generated in the OKLCH color space, which is perceptually uniform:
    /// equal angular steps in hue produce equal perceived color differences. This
    /// avoids the clustering problem inherent in HSB, where large swaths of the hue
    /// wheel (greens, purples) look indistinguishable at moderate saturation.
    ///
    /// Colors automatically adapt to the current appearance: dark mode uses slightly
    /// lower lightness and higher chroma, while light mode uses higher lightness with
    /// gentler chroma.
    ///
    /// The same input always produces the same hue, even across app restarts.
    init(stableColorFor name: String) {
        self.init(nsColor: NSColor(stableColorFor: name, alpha: 1))
    }

    // MARK: - OKLCH to sRGB Conversion

    /// Converts an OKLCH color to clamped sRGB components.
    ///
    /// - Parameters:
    ///   - L: Lightness (0–1).
    ///   - C: Chroma (0–~0.4, though values above ~0.15 may clip at some hues).
    ///   - H: Hue in degrees (0–360).
    /// - Returns: A tuple of (red, green, blue) each in the range 0–1.
    fileprivate static func oklchToSRGB(L: Double, C: Double, H: Double) -> (CGFloat, CGFloat, CGFloat) {
        // OKLCH → OKLab (polar to cartesian).
        let hRad = H * .pi / 180.0
        let a = C * cos(hRad)
        let b = C * sin(hRad)

        // OKLab → approximate linear sRGB via LMS intermediary.
        // Matrices from Björn Ottosson: https://bottosson.github.io/posts/oklab/
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b

        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        let lr = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        // Linear sRGB → sRGB (gamma).
        return (
            CGFloat(linearToSRGB(lr)),
            CGFloat(linearToSRGB(lg)),
            CGFloat(linearToSRGB(lb))
        )
    }

    /// Applies the sRGB gamma transfer function and clamps to [0, 1].
    private static func linearToSRGB(_ x: Double) -> Double {
        let clamped = min(1, max(0, x))
        if clamped <= 0.0031308 {
            return 12.92 * clamped
        }
        return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
    }

    /// DJB2 hash — a simple, fast, deterministic string hash.
    fileprivate static func djb2Hash(_ string: String) -> UInt {
        var hash: UInt = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt(byte)
        }
        return hash
    }
}

// MARK: - Preview

private let previewSampleNames = [
    "@alice:matrix.org", "@bob:matrix.org", "@charlie:matrix.org",
    "@dave:matrix.org", "@eve:matrix.org", "@frank:matrix.org",
    "@grace:matrix.org", "@heidi:matrix.org", "@ivan:matrix.org",
    "@judy:matrix.org", "@karl:matrix.org", "@liam:matrix.org",
    "@mallory:matrix.org", "@nora:matrix.org", "@oscar:matrix.org",
    "@pat:matrix.org", "@quinn:matrix.org", "@ruth:matrix.org",
    "@steve:matrix.org", "@trudy:matrix.org", "@ursula:matrix.org",
    "@victor:matrix.org", "@wendy:matrix.org", "@xander:matrix.org",
    "@yara:matrix.org", "@zoe:matrix.org",
]

/// Visualises the full OKLCH hue sweep so you can evaluate the color distribution.
private struct StableNameColorPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OKLCH (New)")
                .font(.title2).bold()

            // Full 360° hue sweep — one swatch per degree.
            Text("Full Hue Sweep (0–359°)")
                .font(.headline)
            HStack(spacing: 0) {
                ForEach(0..<360, id: \.self) { hue in
                    let (r, g, b) = Color.oklchToSRGB(
                        L: 0.55, C: 0.12, H: Double(hue)
                    )
                    Color(red: Double(r), green: Double(g), blue: Double(b))
                }
            }
            .frame(height: 40)
            .clipShape(.rect(cornerRadius: 6))

            // Sample names with their derived colors.
            Text("Sample Names")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 8)],
                spacing: 8
            ) {
                ForEach(previewSampleNames, id: \.self) { name in
                    HStack {
                        Circle()
                            .fill(Color(stableColorFor: name))
                            .frame(width: 24, height: 24)
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(width: 600)
    }
}

/// Shows the previous HSB-based algorithm for comparison.
private struct LegacyHSBPreview: View {
    /// Reproduces the old HSB color generation for comparison.
    private func legacyColor(for name: String) -> Color {
        var hash: UInt = 5381
        for byte in name.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt(byte)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.75)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HSB (Old)")
                .font(.title2).bold()

            // Full 360° hue sweep — one swatch per degree.
            Text("Full Hue Sweep (0–359°)")
                .font(.headline)
            HStack(spacing: 0) {
                ForEach(0..<360, id: \.self) { hue in
                    Color(hue: Double(hue) / 360.0, saturation: 0.45, brightness: 0.75)
                }
            }
            .frame(height: 40)
            .clipShape(.rect(cornerRadius: 6))

            // Sample names with their derived colors.
            Text("Sample Names")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 8)],
                spacing: 8
            ) {
                ForEach(previewSampleNames, id: \.self) { name in
                    HStack {
                        Circle()
                            .fill(legacyColor(for: name))
                            .frame(width: 24, height: 24)
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(width: 600)
    }
}

#Preview("OKLCH (New)") {
    StableNameColorPreview()
}

#Preview("HSB (Old)") {
    LegacyHSBPreview()
}
