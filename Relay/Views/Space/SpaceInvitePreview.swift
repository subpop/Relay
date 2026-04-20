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

/// A centered preview view for space invitations showing metadata and accept/decline buttons.
struct SpaceInvitePreview: View {
    let invite: RoomSummary
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            AvatarView(name: invite.name, mxcURL: invite.avatarURL, size: 80)

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    Text("Space Invitation")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                Text(invite.name)
                    .font(.title)
                    .bold()

                if let topic = invite.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }

                if let inviterName = invite.inviterName {
                    Text("Invited by \(inviterName)")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 40)

            HStack(spacing: 12) {
                Button("Decline", role: .destructive, action: onDecline)
                    .controlSize(.large)

                Button("Accept & Join", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
