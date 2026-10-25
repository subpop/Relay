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

/// A poll card: the question, one row per answer, and a footer. Tapping an
/// answer casts or changes the local user's vote.
///
/// Disclosed polls reveal counts once the user has voted. Undisclosed polls
/// reveal counts only after they end. Ended polls lock and mark the winners.
struct PollMessageView: View {
    let poll: PollSummary

    /// Sender ID, used for the stable per-sender bubble color.
    let senderID: String

    /// Whether the message was sent by the local user.
    let isOutgoing: Bool

    /// Called with the new selection of answer IDs. An empty array retracts.
    let onVote: ([String]) -> Void

    /// Ends the poll. The parent binds the poll event ID.
    let onEndPoll: () -> Void

    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false
    @AppStorage(OutgoingBubbleColor.userDefaultsKey) private var outgoingBubbleColor = OutgoingBubbleColor.accent

    @Environment(\.timelineActions) private var actions

    private var style: BubbleStyle {
        .message(
            isOutgoing: isOutgoing,
            senderID: senderID,
            coloredBubbles: coloredBubbles,
            outgoingColor: outgoingBubbleColor)
    }

    private var canVote: Bool {
        !poll.isEnded && actions.permissions?.canSendMessages == true
    }

    private var canEndPoll: Bool {
        !poll.isEnded && actions.currentUserID == senderID
    }

    private var showResults: Bool {
        poll.isEnded || (poll.kind == .disclosed && !poll.ownSelections.isEmpty)
    }

    private var caption: String {
        if poll.isEnded { return "Poll ended" }
        return poll.maxSelections > 1 ? "Select up to \(poll.maxSelections)" : "Select one"
    }

    private var footer: String? {
        if showResults {
            return poll.totalVotes == 1 ? "1 vote" : "\(poll.totalVotes) votes"
        }
        if poll.kind == .undisclosed && !poll.isEnded {
            return "Results will be shown when the poll ends"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.callout)
                    .foregroundStyle(style.usesWhiteText ? .white : .accentColor)
                    .frame(width: 26, height: 26)
                    .background(
                        style.usesWhiteText ? .white.opacity(0.2) : .accentColor.opacity(0.15),
                        in: .rect(cornerRadius: 7))

                Text(poll.question)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if poll.isEnded {
                    Text("Ended")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(style.usesWhiteText ? .white.opacity(0.85) : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            style.usesWhiteText ? .white.opacity(0.2) : .secondary.opacity(0.2),
                            in: .capsule)
                }
            }

            Text(caption)
                .scaledChromeFont(.caption1)
                .foregroundStyle(style.usesWhiteText ? .white.opacity(0.7) : .secondary)

            VStack(spacing: 6) {
                ForEach(poll.answers, id: \.id) { answer in
                    PollAnswerRow(
                        answer: answer,
                        totalVotes: poll.totalVotes,
                        isSelected: poll.ownSelections.contains(answer.id),
                        isMultiple: poll.maxSelections > 1,
                        showResults: showResults,
                        isWinner: poll.winningAnswerIds.contains(answer.id),
                        isEnabled: canVote,
                        usesWhiteText: style.usesWhiteText,
                        onTap: {
                            let selection = poll.selection(toggling: answer.id)
                            if Set(selection) != poll.ownSelections {
                                onVote(selection)
                            }
                        })
                }
            }

            if footer != nil || canEndPoll {
                HStack {
                    if let footer {
                        Text(footer)
                            .scaledChromeFont(.caption1)
                            .foregroundStyle(style.usesWhiteText ? .white.opacity(0.7) : .secondary)
                    }
                    Spacer()
                    if canEndPoll {
                        Button("End poll", systemImage: "stop.circle") {
                            onEndPoll()
                        }
                        .buttonStyle(.plain)
                        .scaledChromeFont(.caption1)
                        .foregroundStyle(style.usesWhiteText ? .white.opacity(0.85) : .secondary)
                    }
                }
            }
        }
        .padding(.horizontal, BubbleStyle.horizontalPadding)
        .padding(.vertical, BubbleStyle.verticalPadding)
        .frame(minWidth: 200, maxWidth: 300, alignment: .leading)
        .background(style.backgroundColor)
        .foregroundStyle(style.usesWhiteText ? .white : .primary)
    }
}

extension PollSummary {
    /// The selection after tapping `answerID`, in answer order. Single-select
    /// replaces the selection, and tapping the only selection clears it.
    /// Multi-select toggles, and taps past `maxSelections` are ignored.
    func selection(toggling answerID: String) -> [String] {
        var selected = ownSelections
        if maxSelections <= 1 {
            selected = selected == [answerID] ? [] : [answerID]
        } else if selected.contains(answerID) {
            selected.remove(answerID)
        } else if selected.count < maxSelections {
            selected.insert(answerID)
        }
        return answers.map(\.id).filter { selected.contains($0) }
    }
}

/// Press feedback without dimming: the row keeps full opacity when the poll
/// is locked or the user can't vote, so ended results stay readable.
private struct PollAnswerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// One answer row. Interactive rows render as buttons; locked rows render the
/// same content without a button so they never dim.
private struct PollAnswerRow: View {
    let answer: PollSummary.Answer
    let totalVotes: Int
    let isSelected: Bool
    let isMultiple: Bool
    let showResults: Bool
    let isWinner: Bool
    let isEnabled: Bool
    let usesWhiteText: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    private var accessibilityLabel: String {
        var label = answer.text
        if showResults {
            label += answer.voteCount == 1 ? ", 1 vote" : ", \(answer.voteCount) votes"
        }
        if isWinner {
            label += ", winning answer"
        }
        return label
    }

    var body: some View {
        if isEnabled {
            Button(action: onTap) {
                PollAnswerRowContent(
                    answer: answer,
                    totalVotes: totalVotes,
                    isSelected: isSelected,
                    isMultiple: isMultiple,
                    showResults: showResults,
                    isWinner: isWinner,
                    usesWhiteText: usesWhiteText,
                    isHovering: isHovering)
            }
            .buttonStyle(PollAnswerButtonStyle())
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            PollAnswerRowContent(
                answer: answer,
                totalVotes: totalVotes,
                isSelected: isSelected,
                isMultiple: isMultiple,
                showResults: showResults,
                isWinner: isWinner,
                usesWhiteText: usesWhiteText,
                isHovering: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// The answer row's visuals: selection glyph, text, counts, and the animated
/// share-of-votes bar behind it.
private struct PollAnswerRowContent: View {
    let answer: PollSummary.Answer
    let totalVotes: Int
    let isSelected: Bool
    let isMultiple: Bool
    let showResults: Bool
    let isWinner: Bool
    let usesWhiteText: Bool
    let isHovering: Bool

    private var share: Double {
        totalVotes > 0 ? Double(answer.voteCount) / Double(totalVotes) : 0
    }

    private var percentText: String {
        "\(Int((share * 100).rounded()))%"
    }

    private var glyph: String {
        switch (isMultiple, isSelected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "checkmark.circle.fill"
        case (false, false): "circle"
        }
    }

    private var glyphStyle: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(usesWhiteText ? .white : .accentColor)
        }
        return AnyShapeStyle(usesWhiteText ? .white.opacity(0.75) : .secondary)
    }

    private var baseFill: Color {
        if usesWhiteText {
            return .white.opacity(isHovering ? 0.22 : 0.13)
        }
        return .primary.opacity(isHovering ? 0.12 : 0.07)
    }

    private var barFill: Color {
        usesWhiteText ? .white.opacity(0.28) : .accentColor.opacity(0.3)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .foregroundStyle(glyphStyle)
            Text(answer.text)
                .bold(isWinner)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showResults {
                Text("\(answer.voteCount) · \(percentText)")
                    .monospacedDigit()
                    .foregroundStyle(usesWhiteText ? .white.opacity(0.85) : .secondary)
            }
            if isWinner {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(usesWhiteText ? .white : .accentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(.rect(cornerRadius: 10))
        .background(baseFill, in: .rect(cornerRadius: 10))
        .background(alignment: .leading) {
            if showResults {
                let share = share
                barFill
                    .visualEffect { content, _ in
                        content.scaleEffect(x: share, y: 1, anchor: .leading)
                    }
                    .animation(.smooth(duration: 0.25), value: share)
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        usesWhiteText ? .white.opacity(0.8) : .accentColor,
                        lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Previews

private let pollPreviewAnswers = [
    PollSummary.Answer(id: "a1", text: "Pizza", voteCount: 3),
    PollSummary.Answer(id: "a2", text: "Tacos", voteCount: 1),
    PollSummary.Answer(id: "a3", text: "Sushi", voteCount: 0),
]

@MainActor
private func pollPreviewActions() -> TimelineActions {
    let actions = TimelineActions(currentUserID: "@me:matrix.org")
    actions.permissions = RoomPermissions(canSendMessages: true)
    return actions
}

#Preview("Open, not voted") {
    PollMessageView(
        poll: PollSummary(
            question: "Lunch?", answers: pollPreviewAnswers, totalVotes: 4),
        senderID: "@alice:matrix.org",
        isOutgoing: false,
        onVote: { _ in },
        onEndPoll: {}
    )
    .environment(\.timelineActions, pollPreviewActions())
    .padding()
    .frame(width: 450)
}

#Preview("Disclosed, voted") {
    PollMessageView(
        poll: PollSummary(
            question: "Lunch?", answers: pollPreviewAnswers, totalVotes: 4,
            ownSelections: ["a1"]),
        senderID: "@me:matrix.org",
        isOutgoing: true,
        onVote: { _ in },
        onEndPoll: {}
    )
    .environment(\.timelineActions, pollPreviewActions())
    .padding()
    .frame(width: 450)
}

#Preview("Undisclosed, voted") {
    PollMessageView(
        poll: PollSummary(
            question: "Secret ballot", answers: pollPreviewAnswers,
            kind: .undisclosed, totalVotes: 4, ownSelections: ["a2"]),
        senderID: "@alice:matrix.org",
        isOutgoing: false,
        onVote: { _ in },
        onEndPoll: {}
    )
    .environment(\.timelineActions, pollPreviewActions())
    .padding()
    .frame(width: 450)
}

#Preview("Ended") {
    PollMessageView(
        poll: PollSummary(
            question: "Lunch?", answers: pollPreviewAnswers, totalVotes: 4,
            ownSelections: ["a2"], isEnded: true, winningAnswerIds: ["a1"]),
        senderID: "@alice:matrix.org",
        isOutgoing: false,
        onVote: { _ in },
        onEndPoll: {}
    )
    .environment(\.timelineActions, pollPreviewActions())
    .padding()
    .frame(width: 450)
}

#Preview("Multi-select") {
    PollMessageView(
        poll: PollSummary(
            question: "Which toppings?", answers: pollPreviewAnswers,
            maxSelections: 2, totalVotes: 4, ownSelections: ["a1", "a3"]),
        senderID: "@alice:matrix.org",
        isOutgoing: false,
        onVote: { _ in },
        onEndPoll: {}
    )
    .environment(\.timelineActions, pollPreviewActions())
    .padding()
    .frame(width: 450)
}
