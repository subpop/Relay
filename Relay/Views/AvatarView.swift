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

/// A circular avatar that displays a user's or room's profile image, falling back to colored initials.
///
/// When an `mxcURL` is provided, the view asynchronously loads a thumbnail from the Matrix
/// homeserver. If no URL is available or the download fails, a deterministic colored circle
/// with the entity's initials is shown instead.
struct AvatarView: View {
    @Environment(\.matrixService) private var matrixService

    /// The display name used to generate initials and the fallback background color.
    let name: String

    /// The `mxc://` URL for the avatar image, or `nil` to always show initials.
    let mxcURL: String?

    /// The diameter of the avatar circle in points.
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: mxcURL) {
            guard let mxcURL else { return }
            image = await matrixService.avatarThumbnail(mxcURL: mxcURL, size: size)
        }
    }

    private var initialsView: some View {
        ZStack {
            Circle()
                .fill(color(for: name))

            Text(initials(for: name))
                .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private func initials(for name: String) -> String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func color(for name: String) -> Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.7)
    }
}

#Preview("Initials") {
    HStack(spacing: 16) {
        AvatarView(name: "Alice Smith", mxcURL: nil, size: 48)
        AvatarView(name: "Bob", mxcURL: nil, size: 36)
        AvatarView(name: "Charlie Davis", mxcURL: nil, size: 28)
    }
    .padding()
}

#Preview("Sizes") {
    VStack(spacing: 12) {
        AvatarView(name: "Relay User", mxcURL: nil, size: 64)
        AvatarView(name: "Relay User", mxcURL: nil, size: 36)
        AvatarView(name: "Relay User", mxcURL: nil, size: 24)
    }
    .padding()
}
