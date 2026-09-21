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

/// Renders a collapsed group of consecutive system events as a single
/// summary row with a disclosure control. When expanded, the individual
/// events are shown using ``SystemEventView``.
struct CollapsedSystemEventsView: View {
    let messages: [ObservableTimelineEvent]
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
                    ForEach(messages.enumerated(), id: \.element.eventId) { index, message in
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

        let membership = messages.count(where: { if case .state = $0.kind { true } else { false } })
        let profileChange = messages.count(where: { if case .profileChange = $0.kind { true } else { false } })
        let stateEvent = messages.count(where: {
            if case .state = $0.kind { true } else { false }
        })
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

private func previewEvent(
    _ id: String, sender: String, name: String, body: String, kind: MessageKind
) -> ObservableTimelineEvent {
    PreviewFixtures.event(id, sender: sender, displayName: name, body: body, kind: kind)
}

#Preview("Collapsed") {
    CollapsedSystemEventsView(
        messages: [
            previewEvent("1", sender: "@alice:matrix.org", name: "Alice",
                         body: "Alice joined the room.",
                         kind: .state(type: "m.room.member", description: "Alice joined the room.")),
            previewEvent("2", sender: "@bob:matrix.org", name: "Bob",
                         body: "Bob joined the room.",
                         kind: .state(type: "m.room.member", description: "Bob joined the room.")),
            previewEvent("3", sender: "@charlie:matrix.org", name: "Charlie",
                         body: "Charlie changed their name to Chuck.",
                         kind: .profileChange(description: "Charlie changed their name to Chuck.")),
            previewEvent("4", sender: "@dave:matrix.org", name: "Dave",
                         body: "Dave left the room.",
                         kind: .state(type: "m.room.member", description: "Dave left the room.")),
            previewEvent("5", sender: "@eve:matrix.org", name: "Eve",
                         body: "Eve joined the room.",
                         kind: .state(type: "m.room.member", description: "Eve joined the room.")),
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
            previewEvent("1", sender: "@alice:matrix.org", name: "Alice",
                         body: "Alice joined the room.",
                         kind: .state(type: "m.room.member", description: "Alice joined the room.")),
            previewEvent("2", sender: "@bob:matrix.org", name: "Bob",
                         body: "Bob joined the room.",
                         kind: .state(type: "m.room.member", description: "Bob joined the room.")),
            previewEvent("3", sender: "@charlie:matrix.org", name: "Charlie",
                         body: "Charlie changed their name to Chuck.",
                         kind: .profileChange(description: "Charlie changed their name to Chuck.")),
            previewEvent("4", sender: "@dave:matrix.org", name: "Dave",
                         body: "Dave left the room.",
                         kind: .state(type: "m.room.member", description: "Dave left the room.")),
            previewEvent("5", sender: "@eve:matrix.org", name: "Eve",
                         body: "Eve joined the room.",
                         kind: .state(type: "m.room.member", description: "Eve joined the room.")),
        ],
        groupID: "1",
        expandedGroups: state
    )
    .padding()
    .frame(width: 450)
}
