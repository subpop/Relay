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

/// Displays a compact "Emojis" control that overlays a message bubble.
///
/// Collapsed, it shows a filled smiley-face icon at the bubble's corner with no
/// background. Clicking it expands a material capsule that hugs the reaction
/// row in the bubble's top corner (growing from the corner) listing every
/// reaction; clicking a reaction badge toggles that reaction without closing
/// it. When expanded the button becomes an xmark that collapses it. The button
/// sits at the leading end for outgoing messages and at the trailing end for
/// incoming ones.
struct MessageReactionBadges: View {
    let reactions: [TimelineMessage.ReactionGroup]

    /// Whether the message is outgoing (determines expansion direction).
    let isOutgoing: Bool

    /// Whether colored bubbles are enabled (determines badge fill color).
    let coloredBubbles: Bool

    /// Called with the emoji key when the user taps a reaction badge.
    let onToggle: (String) -> Void

    /// The diameter of each reaction badge circle and the smiley button.
    private static let badgeSize: CGFloat = 22

    /// The horizontal spacing between badges in the expanded row.
    private static let expandedSpacing: CGFloat = 2

    /// The overlay's offset from the bubble's corner.
    private static let cornerOffsetX: CGFloat = 8
    private static let cornerOffsetY: CGFloat = -11

    @State private var isExpanded = false

    var body: some View {
        ZStack(alignment: isOutgoing ? .topLeading : .topTrailing) {
            if isExpanded {
                expandedContent
                    .transition(expandTransition)
            } else {
                collapsedPreview
                    .background(Capsule().fill(.ultraThickMaterial))
                    .transition(expandTransition)
            }
        }
        .offset(x: isOutgoing ? -Self.cornerOffsetX : Self.cornerOffsetX, y: Self.cornerOffsetY)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: isOutgoing ? .topLeading : .topTrailing
        )
        .animation(.spring(duration: 0.3, bounce: 0.2), value: isExpanded)
    }

    /// The expanded overlay: the reaction row with a material background that
    /// hugs its contents, pinned to the bubble's top corner.
    private var expandedContent: some View {
        expandedRow
            .background(BubbleStyle.shape.fill(.ultraThickMaterial))
    }

    /// The row of reaction badges, with the expand/collapse button at the
    /// leading end for outgoing messages and the trailing end for incoming
    /// ones.
    private var expandedRow: some View {
        HStack(spacing: Self.expandedSpacing) {
            if isOutgoing {
                expandButton
            }

            ForEach(reactions) { reaction in
                ReactionBadge(
                    reaction: reaction,
                    coloredBubbles: coloredBubbles,
                    onToggle: { onToggle(reaction.key) }
                )
                .transition(expandTransition)
            }

            if !isOutgoing {
                expandButton
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    /// The button that expands the control (filled smiley on a material circle)
    /// and collapses it (plain xmark). Leading for outgoing messages, trailing
    /// for incoming ones.
    private var expandButton: some View {
        Button(action: { isExpanded.toggle() }) {
            Image(systemName: isExpanded ? "xmark" : "face.smiling")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .frame(width: Self.badgeSize, height: Self.badgeSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// The grow-from-corner transition used when expanding and collapsing.
    private var expandTransition: AnyTransition {
        .scale(scale: 0.5, anchor: isOutgoing ? .topLeading : .topTrailing)
            .combined(with: .opacity)
    }
    
    /// Collapsed state: shows up to 3 of the actual reaction emojis stacked together
    private var collapsedPreview: some View {
        Group {
            if reactions.isEmpty {
                expandButton
            } else {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 2) {
                        ForEach(reactions.prefix(3)) { reaction in
                            Text(reaction.key)
                                .font(.system(size: 12))
                        }
                        if reactions.count > 3 {
                            Text("+\(reactions.count - 3)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(.secondary, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: Self.badgeSize)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A single reaction badge: emoji in a small circle with optional count and border.
///
/// When colored bubbles are enabled, the circle fill color is derived from the
/// first sender of this reaction via ``Color/init(stableColorFor:)``, so each reactor gets
/// their own color. Otherwise a neutral gray is used.
private struct ReactionBadge: View {
    let reaction: TimelineMessage.ReactionGroup
    let coloredBubbles: Bool
    let onToggle: () -> Void
    @State private var isHovering = false

    private static let size: CGFloat = 22

    private var fillColor: Color {
        if coloredBubbles, let firstSender = reaction.senderIDs.first {
            return Color(stableColorFor: firstSender)
        }
        return Color(.accent)
    }

    var body: some View {
        HStack(spacing: 4) {
                    Button(action: onToggle) {
                        Text(reaction.key)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                        Text("\(reaction.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(reaction.highlightedByCurrentUser ? .white : .secondary)
                            .onHover{
                                hovering in isHovering = hovering
                            }
                            .popover(isPresented: $isHovering, arrowEdge: .top) {
                                       ReactionAuthors(reaction: reaction)
                                           .padding(8)
                                   }
                    }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(reaction.highlightedByCurrentUser ? fillColor : .secondary.opacity(0.15))
                )
            }
}

/// Shows the authors of each reaction up to maxShown.
private struct ReactionAuthors: View {
    let reaction: TimelineMessage.ReactionGroup
    let maxShown = 5
    var body: some View {
        VStack(spacing: 2) {
            ForEach(reaction.senderIDs.prefix(maxShown), id:\.self){
                senderId in Text(senderId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if reaction.senderIDs.count > maxShown{
                    Text("and \(reaction.senderIDs.count - maxShown) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
            }
        }
    }
}

// MARK: - Previews

private let sampleReactions: [TimelineMessage.ReactionGroup] = [
    .init(key: "\u{1F389}", count: 3,
          senderIDs: ["@alice:matrix.org", "@bob:matrix.org", "@charlie:matrix.org"],
          highlightedByCurrentUser: false),
    .init(key: "\u{1F680}", count: 1,
          senderIDs: ["@alice:matrix.org"],
          highlightedByCurrentUser: false),
    .init(key: "\u{1F44D}", count: 2,
          senderIDs: ["@bob:matrix.org", "@me:matrix.org"],
          highlightedByCurrentUser: true),
    .init(key: "\u{1F44E}", count: 1,
          senderIDs: ["@alice:matrix.org"],
          highlightedByCurrentUser: false)
]

#Preview("Outgoing") {
    VStack {
        Text("Check out this new feature!")
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(.rect(cornerRadius: 17))
            .overlay(alignment: .topLeading) {
                MessageReactionBadges(
                    reactions: sampleReactions,
                    isOutgoing: true,
                    coloredBubbles: false,
                    onToggle: { _ in }
                )
            }
            .padding(.top, 11)
    }
    .padding(40)
}

#Preview("Incoming") {
    VStack {
        Text("Nice, rooms are loading way faster now.")
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.unemphasizedSelectedContentBackgroundColor))
            .clipShape(.rect(cornerRadius: 17))
            .overlay(alignment: .topTrailing) {
                MessageReactionBadges(
                    reactions: sampleReactions,
                    isOutgoing: false,
                    coloredBubbles: false,
                    onToggle: { _ in }
                )
            }
            .padding(.top, 11)
    }
    .padding(40)
}

#Preview("Single Reaction") {
    VStack {
        Text("Hello!")
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.unemphasizedSelectedContentBackgroundColor))
            .clipShape(.rect(cornerRadius: 17))
            .overlay(alignment: .topTrailing) {
                MessageReactionBadges(
                    reactions: [
                        .init(key: "\u{2764}\u{FE0F}", count: 1,
                              senderIDs: ["@me:matrix.org"],
                              highlightedByCurrentUser: true),
                    ],
                    isOutgoing: false,
                    coloredBubbles: false,
                    onToggle: { _ in }
                )
            }
            .padding(.top, 11)
    }
    .padding(40)
}
