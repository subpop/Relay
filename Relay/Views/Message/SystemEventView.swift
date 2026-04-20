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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .imageScale(.small)
            Text(message.body)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch message.kind {
        case .membership:
            "person.2"
        case .profileChange:
            "person.text.rectangle"
        case .stateEvent:
            "gearshape"
        default:
            "info.circle"
        }
    }
}
