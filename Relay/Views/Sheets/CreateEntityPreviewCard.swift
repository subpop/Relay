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

struct CreateEntityPreviewCard: View {
    let name: String
    let topic: String
    let isSpace: Bool
    let avatarImage: NSImage?
    let onChooseAvatar: () -> Void

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Group {
                    if let avatarImage {
                        Image(nsImage: avatarImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        AvatarView(
                            name: name.isEmpty ? (isSpace ? "Space" : "Room") : name,
                            mxcURL: nil,
                            size: 56,
                            shape: isSpace
                                ? AnyShape(.rect(cornerRadius: 12))
                                : AnyShape(Circle())
                        )
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(isSpace
                    ? AnyShape(.rect(cornerRadius: 12))
                    : AnyShape(Circle()))
                .badge(at: .bottomTrailing) {
                    Button { onChooseAvatar() } label: {
                        Image(systemName: "camera.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .badgeIcon(fill: .tint, diameter: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Change avatar")
                }

                VStack(alignment: .leading, spacing: 4) {
                    if name.isEmpty {
                        Text(isSpace ? "Space name" : "Room name")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(name)
                    }

                    if topic.isEmpty {
                        Text(isSpace ? "Space description" : "Room description")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(topic)
                    }
                }
                .lineLimit(2)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
