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

// MARK: - Typing Indicator Overlay

/// A lightweight view that observes only `viewModel.typingUserDisplayNames`,
/// isolating typing-state changes from ``TimelineView/body`` re-evaluation.
/// Without this, every typing notification would trigger a full `body`
/// recompute, rebuilding `messageRows` and passing them through the
/// representable boundary — even though the message data hasn't changed.
struct TypingIndicatorOverlay: View {
    let viewModel: any TimelineViewModelProtocol

    var body: some View {
        let names = viewModel.typingUserDisplayNames
        ZStack(alignment: .leading) {
            if !names.isEmpty {
                HStack(spacing: 6) {
                    TypingBubble()
                    Text(typingLabel(for: names))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.3), value: names.isEmpty)
    }

    private func typingLabel(for names: [String]) -> String {
        switch names.count {
        case 1:
            return "\(names[0]) is typing…"
        case 2:
            return "\(names[0]) and \(names[1]) are typing…"
        default:
            return "\(names[0]) and \(names.count - 1) others are typing…"
        }
    }
}

// MARK: - Typing Bubble Animation

struct TypingBubble: View {
    private let startDate = Date()

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = dotPhase(elapsed: elapsed, index: index)
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.6 + 0.4 * phase)
                        .opacity(0.4 + 0.6 * phase)
                }
            }
        }
    }

    /// Returns a 0...1 pulsing value for each dot, staggered by index.
    private func dotPhase(elapsed: TimeInterval, index: Int) -> Double {
        let period = 1.8 // full cycle duration in seconds
        let delay = Double(index) * 0.15
        // swiftlint:disable:next identifier_name
        let t = (elapsed + delay).truncatingRemainder(dividingBy: period) / period
        return sin(t * .pi)
    }
}
