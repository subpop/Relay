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

/// A compact, centered row for displaying system events in the timeline.
///
/// System events include membership changes (joins, leaves, bans), profile
/// changes (display name, avatar), and room state changes (name, topic,
/// encryption). They are rendered as small, centered text with an inline
/// SF Symbol icon — no avatar, no chat bubble, no swipe actions.
struct SystemEventView: View {
    let message: TimelineMessage

    @Environment(\.timelineActions) private var actions

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .imageScale(.small)
            Text(message.attributedBody ?? AttributedString(message.body))
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

    private var iconName: String {
        switch message.kind {
        case .membership(_):
            "person.2"
        case .profileChange(_):
            "person.text.rectangle"
        case .callEvent(_):
            "phone.fill"
        case .stateEvent(_):
            "gearshape"
        default:
            "info.circle"
        }
    }
}

// MARK: - Previews

private func previewAttributedBody(_ name: String, userId: String, suffix: String) -> AttributedString {
    var linked = AttributedString(name)
    linked.link = URL(string: "https://matrix.to/#/\(userId)")
    return linked + AttributedString(suffix)
}

#Preview("Membership") {
    SystemEventView(
        message: .init(
            id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
            body: "Alice joined the room",
            timestamp: .now, isOutgoing: false,
            kind: .membership(previewAttributedBody("Alice", userId: "@alice:matrix.org", suffix: " joined the room"))
        )
    )
    .padding()
    .frame(width: 450)
}

#Preview("Profile Change") {
    SystemEventView(
        message: .init(
            id: "2", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
            body: "Bob updated their avatar",
            timestamp: .now, isOutgoing: false,
            kind: .profileChange(previewAttributedBody("Bob", userId: "@bob:matrix.org", suffix: " updated their avatar"))
        )
    )
    .padding()
    .frame(width: 450)
}
