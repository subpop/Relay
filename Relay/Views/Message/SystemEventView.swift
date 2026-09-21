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

/// A compact, centered row for displaying system events in the timeline.
///
/// System events include membership changes (joins, leaves, bans), profile
/// changes (display name, avatar), and room state changes (name, topic,
/// encryption). They are rendered as small, centered text with an inline
/// SF Symbol icon — no avatar, no chat bubble, no swipe actions.
struct SystemEventView: View {
    let message: ObservableTimelineEvent

    @Environment(\.timelineActions) private var actions

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .imageScale(.small)
            Text(attributedDescription)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .environment(\.openURL, OpenURLAction { url in
            if let uri = MatrixURI(url: url), uri.isUser, case .user(let id) = uri {
                actions.userTap(id)
                return .handled
            }
            return .systemAction
        })
    }

    private var description: String {
        switch message.kind {
        case .state(_, let description),
            .profileChange(let description),
            .callEvent(_, let description):
            description
        default:
            message.body
        }
    }

    /// Description with user deep-links on the sender's and membership
    /// target's names. Taps route through the `openURL` interception
    /// above into `actions.userTap` (the member inspector).
    private var attributedDescription: AttributedString {
        SystemEventLinker.linkedDescription(
            description,
            senderName: message.senderDisplayName,
            senderID: message.sender.value,
            targetName: message.targetDisplayName,
            targetID: message.targetUserId?.value
        )
    }

    private var iconName: String {
        switch message.kind {
        case .state(let type, _):
            switch type {
            case "m.room.member":
                "person.2"
            case "m.room.create":
                "sparkles"
            case "m.room.avatar":
                "photo"
            case "m.room.power_levels":
                "gearshape"
            case "m.room.encryption":
                "lock.shield"
            case "m.room.tombstone":
                "arrow.up.right.square"
            case "m.room.canonical_alias":
                "link"
            case "m.room.pinned_events":
                "pin"
            case "m.room.join_rules":
                "person.badge.key"
            case "m.room.history_visibility":
                "clock.arrow.circlepath"
            case "m.room.server_acl":
                "server.rack"
            default:
                "info.circle"
            }
        case .profileChange:
            "person.text.rectangle"
        case .callEvent:
            "phone.fill"
        default:
            "info.circle"
        }
    }
}

// MARK: - Previews

#Preview("Membership") {
    SystemEventView(
        message: PreviewFixtures.event(
            "1", sender: "@alice:matrix.org", displayName: "Alice",
            body: "Alice joined the room",
            kind: .state(type: "m.room.member", description: "Alice joined the room")
        )
    )
    .padding()
    .frame(width: 450)
}

#Preview("Profile Change") {
    SystemEventView(
        message: PreviewFixtures.event(
            "2", sender: "@bob:matrix.org", displayName: "Bob",
            body: "Bob updated their avatar",
            kind: .profileChange(description: "Bob updated their avatar")
        )
    )
    .padding()
    .frame(width: 450)
}

#Preview("Kick") {
    SystemEventView(
        message: PreviewFixtures.event(
            "3", sender: "@alice:matrix.org", displayName: "Alice",
            body: "Alice removed Bob",
            kind: .state(type: "m.room.member", description: "Alice removed Bob"),
            targetUserId: "@bob:matrix.org",
            targetDisplayName: "Bob"
        )
    )
    .padding()
    .frame(width: 450)
}
