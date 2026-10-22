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

/// The color of outgoing message bubbles when the Grey bubble style is active.
///
/// Stored as a raw `String` in `@AppStorage(OutgoingBubbleColor.userDefaultsKey)`.
/// ``accent`` follows the accent color chosen in System Settings; the
/// remaining cases are fixed system colors, mirroring the accent color row
/// there.
enum OutgoingBubbleColor: String, CaseIterable, Identifiable {
    case accent
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case cyan

    /// The `UserDefaults` key under which the selection is persisted.
    static let userDefaultsKey = "appearance.outgoingBubbleColor"

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .accent: "Accent Color"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .cyan: "Cyan"
        }
    }

    var color: Color {
        switch self {
        case .accent: Color(nsColor: .controlAccentColor)
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .cyan: .cyan
        }
    }

    /// The text color on a bubble of this color. Yellow is too light for
    /// white text, so its bubbles use black text in both light and dark
    /// appearance.
    var foregroundColor: Color {
        switch self {
        case .yellow: .black
        default: .white
        }
    }
}
