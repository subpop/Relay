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

/// A capsule-shaped pill view for inline mention display in the compose text view.
///
/// ``MentionPillView`` is rendered to a static `NSImage` by ``PillTextAttachment``
/// at creation time. The image is set on the attachment and displayed inline by
/// the `NSTextView`'s layout system. It displays `@DisplayName` in a rounded
/// capsule with the accent color.
struct MentionPillView: View {
    let displayName: String

    var body: some View {
        Text("@\(displayName)")
            .font(.callout)
            .bold()
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.15), in: .capsule)
    }

    // MARK: - Measurement

    /// Horizontal padding inside the capsule (leading + trailing).
    private static let horizontalPadding: CGFloat = 12

    /// Vertical padding inside the capsule (top + bottom).
    private static let verticalPadding: CGFloat = 2

    /// Measures the size the pill will occupy for layout purposes.
    ///
    /// This is called by ``PillTextAttachment/attachmentBounds(for:proposedLineFragment:glyphPosition:characterIndex:)``
    /// to report the correct size before the view provider creates the actual view.
    static func measureSize(displayName: String, font: NSFont) -> CGSize {
        let text = "@\(displayName)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: font.pointSize - 1, weight: .bold),
        ]
        let textSize = text.size(withAttributes: attributes)
        return CGSize(
            width: ceil(textSize.width + horizontalPadding),
            height: ceil(textSize.height + verticalPadding)
        )
    }
}

#Preview {
    MentionPillView(displayName: "Alice Smith")
        .padding()
}
