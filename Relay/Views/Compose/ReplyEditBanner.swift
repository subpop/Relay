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

/// A banner shown above the compose text field when replying to or editing a message.
///
/// Displays a label with an icon and a dismiss button. Animates in/out with a
/// slide + fade transition.
struct ReplyEditBanner: View {
    /// The label text (e.g. "Replying to Alice" or "Editing Message").
    let label: String

    /// The SF Symbol name for the leading icon.
    let systemImage: String

    /// Called when the user dismisses the banner.
    var onDismiss: () -> Void

    var body: some View {
        HStack {
            Label(label, systemImage: systemImage)
                .font(.caption)
                .bold()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss", systemImage: "xmark") {
                onDismiss()
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .foregroundStyle(.tertiary)
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview("Reply") {
    ReplyEditBanner(
        label: "Replying to Alice",
        systemImage: "arrowshape.turn.up.left",
        onDismiss: {}
    )
    .frame(width: 400)
}

#Preview("Editing") {
    ReplyEditBanner(
        label: "Editing Message",
        systemImage: "pencil",
        onDismiss: {}
    )
    .frame(width: 400)
}
