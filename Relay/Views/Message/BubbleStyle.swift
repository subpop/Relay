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

import MatrixKit
import SwiftUI

/// Encapsulates the visual properties of a message bubble: background color,
/// text color, corner radius, and padding. Used by ``MessageBubbleContent``,
/// ``ReplyPreviewBubble``, and ``AudioMessageView`` to ensure consistent styling
/// across all message types.
struct BubbleStyle {
    /// The bubble's background fill color.
    let backgroundColor: Color

    /// The primary text color inside the bubble.
    let foregroundStyle: AnyShapeStyle

    /// The corner radius for the bubble shape.
    static let cornerRadius: CGFloat = 17

    /// Horizontal padding inside the bubble.
    static let horizontalPadding: CGFloat = 12

    /// Vertical padding inside the bubble.
    static let verticalPadding: CGFloat = 7

    /// The continuous rounded rectangle used to clip all bubble content.
    static let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    /// The slightly larger shape used to wrap a reply + message composite.
    static let replyWrapperShape = RoundedRectangle(cornerRadius: 19, style: .continuous)

    /// Whether this style uses white (light-on-dark) text.
    var usesWhiteText: Bool {
        // White text is used when the foreground style is white.
        // This is a convenience for callers that need a Bool (e.g. MessageTextView).
        _usesWhiteText
    }
    private let _usesWhiteText: Bool

    // MARK: - Standard Styles

    /// Returns the bubble style for a regular message (text, image, video, audio).
    static func message(
        isOutgoing: Bool,
        senderID: String,
        coloredBubbles: Bool
    ) -> BubbleStyle {
        let usesWhite = isOutgoing || coloredBubbles
        let background: Color
        if isOutgoing {
            background = coloredBubbles
                ? Color(stableColorFor: senderID)
                : .accentColor
        } else if coloredBubbles {
            background = Color(stableColorFor: senderID)
        } else {
            background = Color(.unemphasizedSelectedContentBackgroundColor)
        }
        return BubbleStyle(
            backgroundColor: background,
            foregroundStyle: AnyShapeStyle(usesWhite ? .white : .primary),
            _usesWhiteText: usesWhite
        )
    }

    /// Returns the bubble style for a reply preview bubble.
    static func reply(
        senderID: String,
        outgoing: Bool,
        coloredBubbles: Bool
    ) -> BubbleStyle {
        let usesWhite = outgoing || coloredBubbles
        let background: Color
        if coloredBubbles {
            background = Color(stableColorFor: senderID)
        } else if outgoing {
            background = .accentColor
        } else {
            background = Color(.systemGray).opacity(0.2)
        }
        return BubbleStyle(
            backgroundColor: background,
            foregroundStyle: AnyShapeStyle(usesWhite ? .white : .primary),
            _usesWhiteText: usesWhite
        )
    }

    /// The bubble style for emote messages (`/me` actions).
    static let emote = BubbleStyle(
        backgroundColor: Color.purple.opacity(0.1),
        foregroundStyle: AnyShapeStyle(.primary),
        _usesWhiteText: false
    )

    /// Returns the bubble style for special message types (redacted, encrypted, etc.).
    static func special(kind: MessageKind) -> BubbleStyle {
        let background: Color = switch kind {
        case .redacted: Color(.systemGray).opacity(0.1)
        case .unableToDecrypt: Color.orange.opacity(0.1)
        default: Color(.systemGray).opacity(0.15)
        }
        let foreground: AnyShapeStyle = switch kind {
        case .unableToDecrypt: AnyShapeStyle(.orange)
        default: AnyShapeStyle(.primary.opacity(0.6))
        }
        return BubbleStyle(
            backgroundColor: background,
            foregroundStyle: foreground,
            _usesWhiteText: false
        )
    }
}
