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

/// Generates a deterministic color from a string (e.g. a Matrix user ID or display name).
///
/// Uses the DJB2 hash algorithm to ensure colors are stable across app launches,
/// unlike Swift's `hashValue` which is randomized per process. The resulting color
/// is suitable for avatar backgrounds and message bubble fills with white text on top.
///
/// Colors automatically adapt to the current appearance: in dark mode they use
/// moderate saturation with reduced brightness, while in light mode they use
/// softer saturation with higher brightness to keep the hue visible without
/// being too vivid.
enum StableNameColor {
    /// Returns a deterministic, appearance-adaptive color derived from the given string.
    ///
    /// The same input always produces the same hue, even across app restarts.
    /// Saturation and brightness adjust automatically based on whether the
    /// system is using a dark or light appearance.
    static func color(for name: String) -> Color {
        let hash = djb2Hash(name)
        let hue = CGFloat(hash % 360) / 360.0

        let nsColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                // Dark mode: moderately saturated, medium brightness.
                NSColor(hue: hue, saturation: 0.5, brightness: 0.65, alpha: 1)
            } else {
                // Light mode: softer saturation, higher brightness.
                NSColor(hue: hue, saturation: 0.45, brightness: 0.75, alpha: 1)
            }
        }
        return Color(nsColor: nsColor)
    }

    /// DJB2 hash — a simple, fast, deterministic string hash.
    private static func djb2Hash(_ string: String) -> UInt {
        var hash: UInt = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt(byte)
        }
        return hash
    }
}
