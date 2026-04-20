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

/// A view modifier that briefly bounces a message bubble larger when the timeline
/// scrolls to focus on it (e.g. via a pinned-message tap, reply navigation, or
/// deep link). The bubble scales up twice in quick succession, then settles back
/// to its natural size — drawing the user's eye without lingering.
struct MessageHighlightModifier: ViewModifier {
    /// Whether this message is the current scroll-to target.
    let isHighlighted: Bool

    /// Called when the highlight animation finishes, so the parent can clear its state.
    var onComplete: (() -> Void)?

    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: isHighlighted) {
                if isHighlighted {
                    runBounce()
                } else {
                    scale = 1
                }
            }
    }

    private func runBounce() {
        // First bounce: scale up
        withAnimation(.spring(duration: 0.15, bounce: 0.3)) {
            scale = 1.06
        }
        Task { @MainActor in
            // Return to normal
            try? await Task.sleep(for: .seconds(0.15))
            withAnimation(.spring(duration: 0.12, bounce: 0.2)) {
                scale = 1
            }
            // Second bounce: smaller and quicker
            try? await Task.sleep(for: .seconds(0.15))
            withAnimation(.spring(duration: 0.12, bounce: 0.25)) {
                scale = 1.035
            }
            // Settle back
            try? await Task.sleep(for: .seconds(0.15))
            withAnimation(.spring(duration: 0.2, bounce: 0.15)) {
                scale = 1
            }
            try? await Task.sleep(for: .seconds(0.2))
            onComplete?()
        }
    }
}

extension View {
    /// Applies a transient pulse highlight when `isHighlighted` becomes `true`.
    func messageHighlight(_ isHighlighted: Bool, onComplete: (() -> Void)? = nil) -> some View {
        modifier(MessageHighlightModifier(isHighlighted: isHighlighted, onComplete: onComplete))
    }
}
