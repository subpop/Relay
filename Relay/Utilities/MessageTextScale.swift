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

/// The user-adjustable zoom level for conversation and compose text.
///
/// Message bodies, mention pills, and the compose field derive their point size
/// from ``baseFont`` rather than `NSFont.systemFontSize` directly, so the whole
/// reading and typing area scales together when the View ▸ Make Text
/// Bigger/Smaller commands change the scale. The factor is persisted in
/// `UserDefaults`; ``increase()``/``decrease()``/``reset()`` update it, drop the
/// now-stale parse caches, and broadcast ``didChangeNotification`` so the
/// timeline can re-measure its rows and the compose bar can re-apply its font.
enum MessageTextScale {
    /// `UserDefaults` key holding the scale factor as a `Double`.
    nonisolated static let userDefaultsKey = "timeline.textScale"

    /// Posted after the scale changes and the parse caches are cleared.
    static let didChangeNotification = Notification.Name("relay.messageTextScaleDidChange")

    /// Neutral scale — message text renders at the system font size.
    nonisolated static let defaultScale: CGFloat = 1
    nonisolated static let minScale: CGFloat = 0.8
    nonisolated static let maxScale: CGFloat = 2.4

    /// Additive step applied by ``increase()`` / ``decrease()``.
    private static let step: CGFloat = 0.1

    /// The current scale factor (1.0 = system size), clamped to a sane range.
    ///
    /// `nonisolated` so message parsing can read it off the main actor; the
    /// backing `UserDefaults` read is itself thread-safe.
    nonisolated static var scale: CGFloat {
        let stored = UserDefaults.standard.object(forKey: userDefaultsKey) as? Double
        let value = stored.map { CGFloat($0) } ?? defaultScale
        return min(max(value, minScale), maxScale)
    }

    /// The base message/compose font point size at the current scale.
    nonisolated static var baseFontSize: CGFloat {
        NSFont.systemFontSize * scale
    }

    /// The base message/compose font at the current scale.
    nonisolated static var baseFont: NSFont {
        NSFont.systemFont(ofSize: baseFontSize)
    }

    @MainActor static func increase() { apply(scale + step) }
    @MainActor static func decrease() { apply(scale - step) }
    @MainActor static func reset() { apply(defaultScale) }

    /// Persists `newValue` (clamped), invalidates the caches that hold text laid
    /// out at the old size, and notifies observers. A no-op when the clamped
    /// value is unchanged, so hitting the limit doesn't churn the timeline.
    @MainActor private static func apply(_ newValue: CGFloat) {
        let clamped = min(max(newValue, minScale), maxScale)
        guard abs(clamped - scale) > 0.001 else { return }
        UserDefaults.standard.set(Double(clamped), forKey: userDefaultsKey)
        MessageBubbleContent.invalidateParseCaches()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

// MARK: - Scaled Chrome Font

private struct ScaledChromeFont: ViewModifier {
    let textStyle: NSFont.TextStyle
    let weight: Font.Weight

    @AppStorage(MessageTextScale.userDefaultsKey) private var scale = Double(MessageTextScale.defaultScale)

    func body(content: Content) -> some View {
        let base = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        content.font(.system(size: base * CGFloat(scale), weight: weight))
    }
}

extension View {
    /// Applies a system font for `textStyle` scaled by the current message
    /// text-zoom level — for chrome (sender names, timestamps) that should track
    /// the conversation text. Reading the scale through `@AppStorage` re-renders
    /// on zoom regardless of any `Equatable` view optimization, and the detached
    /// row-measurement host reads the same value so heights stay correct.
    func scaledChromeFont(_ textStyle: NSFont.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledChromeFont(textStyle: textStyle, weight: weight))
    }
}
