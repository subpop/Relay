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

/// Displays a flow-wrapped row of emoji reaction pills for a message.
///
/// Each pill shows the emoji, an optional count badge, and highlights if the
/// current user has sent that reaction. Tapping a pill toggles the reaction.
struct ReactionsView: View {
    let reactions: [TimelineMessage.ReactionGroup]
    let onToggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    onToggle(reaction.key)
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.key)
                            .font(.body)
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(reaction.highlightedByCurrentUser ? .white : .secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        reaction.highlightedByCurrentUser
                            ? Color.accentColor.opacity(0.25)
                            : Color(.systemGray).opacity(0.12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                reaction.highlightedByCurrentUser
                                    ? Color.accentColor.opacity(0.5)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Flow Layout

/// A custom `Layout` that arranges subviews in a horizontal flow, wrapping to
/// the next line when the available width is exceeded.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        // swiftlint:disable:next identifier_name
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width }
                + CGFloat(max(0, row.count - 1)) * spacing
            height += rowHeight + (i > 0 ? spacing : 0)
            maxRowWidth = max(maxRowWidth, rowWidth)
        }
        return CGSize(width: maxRowWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        // swiftlint:disable:next identifier_name
        var y = bounds.minY
        // swiftlint:disable:next identifier_name
        for (i, row) in rows.enumerated() {
            if i > 0 { y += spacing }
            // swiftlint:disable:next identifier_name
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
                x += size.width + spacing
            }
            y += rowHeight
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width + spacing > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}
