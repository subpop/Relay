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

/// Renders a collapsed group of consecutive system events as a single
/// summary row with a disclosure control. When expanded, the individual
/// events are shown using ``SystemEventView``.
struct CollapsedSystemEventsView: View {
    let messages: [TimelineMessage]
    let groupID: String
    var expandedGroups: ExpandedGroupsState

    private var isExpanded: Bool { expandedGroups.isExpanded(groupID) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedGroups.toggle(groupID)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Text(summary)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(messages.enumerated(), id: \.element.id) { index, message in
                        if index > 0, needsDateHeader(at: index) {
                            Text(dateSectionLabel(for: message.timestamp))
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                        }
                        SystemEventView(message: message)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// Whether the message at the given index falls in a different hour than
    /// its predecessor, warranting a date section header.
    private func needsDateHeader(at index: Int) -> Bool {
        guard index > 0 else { return false }
        return !Calendar.current.isDate(
            messages[index].timestamp,
            equalTo: messages[index - 1].timestamp,
            toGranularity: .hour
        )
    }

    /// Builds a categorical summary string such as "3 membership events,
    /// 2 profile changes".
    private var summary: String {
        var counts: [(label: String, count: Int)] = []

        let membership = messages.count(where: { if case .membership = $0.kind { true } else { false } })
        let profileChange = messages.count(where: { if case .profileChange = $0.kind { true } else { false } })
        let stateEvent = messages.count(where: { if case .stateEvent = $0.kind { true } else { false } })
        let callEvent = messages.count(where: { if case .callEvent = $0.kind { true } else { false } })

        if membership > 0 {
            counts.append((membership == 1 ? "membership event" : "membership events", membership))
        }
        if profileChange > 0 {
            counts.append((profileChange == 1 ? "profile change" : "profile changes", profileChange))
        }
        if stateEvent > 0 {
            counts.append((stateEvent == 1 ? "room change" : "room changes", stateEvent))
        }
        if callEvent > 0 {
            counts.append((callEvent == 1 ? "call event" : "call events", callEvent))
        }

        if counts.isEmpty {
            return "\(messages.count) system events"
        }

        return counts.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
    }
}

// MARK: - Previews

#Preview("Collapsed") {
    CollapsedSystemEventsView(
        messages: [
            .init(id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                  body: "Alice joined the room.", timestamp: .now, isOutgoing: false, kind: .membership(AttributedString("Alice joined the room."))),
            .init(id: "2", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
                  body: "Bob joined the room.", timestamp: .now, isOutgoing: false, kind: .membership(AttributedString("Bob joined the room."))),
            .init(id: "3", senderID: "@charlie:matrix.org", senderDisplayName: "Charlie",
                  body: "Charlie changed their name to Chuck.", timestamp: .now, isOutgoing: false, kind: .profileChange(AttributedString("Charlie changed their name to Chuck."))),
            .init(id: "4", senderID: "@dave:matrix.org", senderDisplayName: "Dave",
                  body: "Dave left the room.", timestamp: .now, isOutgoing: false, kind: .membership(AttributedString("Dave left the room."))),
            .init(id: "5", senderID: "@eve:matrix.org", senderDisplayName: "Eve",
                  body: "Eve joined the room.", timestamp: .now, isOutgoing: false, kind: .membership(AttributedString("Eve joined the room."))),
        ],
        groupID: "1",
        expandedGroups: ExpandedGroupsState()
    )
    .padding()
    .frame(width: 450)
}

#Preview("Expanded") {
    let state = ExpandedGroupsState()
    state.expandedIDs.insert("1")

    return CollapsedSystemEventsView(
        messages: [
            .init(id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                  body: "Alice joined the room.", timestamp: .now, isOutgoing: false, kind: .membership(AttributedString("Alice joined the room."))),
            .init(id: "2", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
                  body: "Bob joined the room.", timestamp: .now, isOutgoing: false, kind: .membership(AttributedString("Bob joined the room."))),
            .init(id: "3", senderID: "@charlie:matrix.org", senderDisplayName: "Charlie",
                  body: "Charlie changed their name to Chuck.", timestamp: .now, isOutgoing: false, kind: .profileChange(AttributedString("Charlie changed their name to Chuck."))),
            .init(id: "4", senderID: "@dave:matrix.org", senderDisplayName: "Dave",
                  body: "Dave left the room.", timestamp: .now, isOutgoing: false, kind: .membership(AttributedString("Dave left the room."))),
            .init(id: "5", senderID: "@eve:matrix.org", senderDisplayName: "Eve",
                  body: "Eve joined the room.", timestamp: .now, isOutgoing: false, kind: .membership(AttributedString("Eve joined the room."))),
        ],
        groupID: "1",
        expandedGroups: state
    )
    .padding()
    .frame(width: 450)
}

#Preview("Expanded with Date Boundaries") {
    let day1 = Date.now.addingTimeInterval(-86400 * 3)
    let day2 = Date.now.addingTimeInterval(-86400 * 2)
    let day3 = Date.now.addingTimeInterval(-86400)
    let state = ExpandedGroupsState()
    state.expandedIDs.insert("1")

    return CollapsedSystemEventsView(
        messages: [
            .init(id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                  body: "Alice joined the room.", timestamp: day1, isOutgoing: false, kind: .membership(AttributedString("Alice joined the room."))),
            .init(id: "2", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
                  body: "Bob joined the room.", timestamp: day1, isOutgoing: false, kind: .membership(AttributedString("Bob joined the room."))),
            .init(id: "3", senderID: "@charlie:matrix.org", senderDisplayName: "Charlie",
                  body: "Charlie left the room.", timestamp: day2, isOutgoing: false, kind: .membership(AttributedString("Charlie left the room."))),
            .init(id: "4", senderID: "@dave:matrix.org", senderDisplayName: "Dave",
                  body: "Dave changed their name to David.", timestamp: day2, isOutgoing: false, kind: .profileChange(AttributedString("Dave changed their name to David."))),
            .init(id: "5", senderID: "@eve:matrix.org", senderDisplayName: "Eve",
                  body: "Eve joined the room.", timestamp: day3, isOutgoing: false, kind: .membership(AttributedString("Eve joined the room."))),
            .init(id: "6", senderID: "@frank:matrix.org", senderDisplayName: "Frank",
                  body: "Frank joined the room.", timestamp: day3, isOutgoing: false, kind: .membership(AttributedString("Frank joined the room."))),
        ],
        groupID: "1",
        expandedGroups: state
    )
    .padding()
    .frame(width: 450)
}
