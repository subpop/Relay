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

import RelayInterface
import SwiftUI

// MARK: - Typing Indicator Row

/// A typing indicator styled to look like an incoming message. Displays
/// overlapping avatars for each typing user and an incoming-style bubble
/// containing animated dots. Designed to be placed at the end of the
/// timeline content so that when a real message arrives, it replaces the
/// indicator in-place with no scroll shift.
struct TypingIndicatorRowView: View {
    let users: [TypingUser]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            avatarStack
            typingBubble
        }
        .frame(maxWidth: 500, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Avatars

    /// Stacked, overlapping avatars — one per typing user.
    private var avatarStack: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(users.prefix(3).reversed()) { user in
                let index = users.firstIndex(where: { $0.id == user.id }) ?? 0
                AvatarView(
                    name: user.displayName,
                    mxcURL: user.avatarURL,
                    size: 28,
                    colorID: user.id
                )
                .offset(x: CGFloat(index) * 16)
            }
        }
        .frame(
            width: 28 + CGFloat(max(users.prefix(3).count - 1, 0)) * 16,
            alignment: .leading
        )
    }

    // MARK: - Bubble

    private var userColors: [Color] {
        users.prefix(3).map { Color(stableColorFor: $0.id) }
    }

    private var typingBubble: some View {
        TypingBubble(colors: userColors)
            .padding(.horizontal, BubbleStyle.horizontalPadding)
            .padding(.vertical, 12)
            .background {
                BreathingColorBackground(colors: userColors)
                    .clipShape(BubbleStyle.shape)
            }
    }
}

// MARK: - Breathing Color Pulse

struct BreathingColorBackground: View {
    private let startDate = Date()
    let colors: [Color]

    var body: some View {
        if colors.isEmpty {
            Color.clear
        } else {
            SwiftUI.TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(startDate)
                let breatheDuration = 3.0
                let cycleDuration = breatheDuration * Double(colors.count)
                let progress = (elapsed.truncatingRemainder(dividingBy: cycleDuration)) / cycleDuration
                let userIndex = min(Int(progress * Double(colors.count)), colors.count - 1)
                let userProgress = (progress * Double(colors.count))
                    .truncatingRemainder(dividingBy: 1)

                let mixAmount = sin(userProgress * .pi)
                let userColor = colors[userIndex]

                userColor.opacity(0.25 + 0.25 * mixAmount)
            }
        }
    }
}

// MARK: - Typing Bubble Animation

struct TypingBubble: View {
    private let startDate = Date()
    let colors: [Color]

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let breatheDuration = 3.0
            let cycleDuration = breatheDuration * Double(max(colors.count, 1))
            let progress = (elapsed.truncatingRemainder(dividingBy: cycleDuration)) / cycleDuration
            let userIndex = min(Int(progress * Double(max(colors.count, 1))), max(colors.count - 1, 0))
            let dotColor = colors.isEmpty ? Color.secondary : colors[userIndex]

            HStack(spacing: 5) {
                ForEach((0..<3).reversed(), id: \.self) { index in
                    let phase = dotPhase(elapsed: elapsed, index: index)
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.6 + 0.4 * phase)
                        .opacity(0.4 + 0.6 * phase)
                }
            }
        }
    }

    /// Returns a 0...1 pulsing value for each dot, staggered by index.
    private func dotPhase(elapsed: TimeInterval, index: Int) -> Double {
        let period = 3.0
        let delay = Double(index) * 0.15
        // swiftlint:disable:next identifier_name
        let t = (elapsed + delay).truncatingRemainder(dividingBy: period) / period
        return sin(t * .pi)
    }
}

// MARK: - Previews

#Preview("Single user typing") {
    TypingIndicatorRowView(users: [
        TypingUser(id: "@alice:matrix.org", displayName: "Alice")
    ])
    .padding()
}

#Preview("Multiple users typing") {
    TypingIndicatorRowView(users: [
        TypingUser(id: "@alice:matrix.org", displayName: "Alice"),
        TypingUser(id: "@bob:matrix.org", displayName: "Bob"),
        TypingUser(id: "@charlie:matrix.org", displayName: "Charlie")
    ])
    .padding()
}
