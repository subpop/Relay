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

import AppKit
import RelayShared
import SwiftUI

/// The main UI for the Relay share extension.
///
/// A typical macOS share sheet layout (i.e. AirDrop): a header bar showing the app
/// identity and a thumbnail, a grid of room avatars in the center, and a
/// bottom action bar with Cancel.
struct ShareView: View {
    let rooms: [ShareableRoom]
    let attachmentCount: Int
    let onSend: (String) async -> Void
    let onCancel: () -> Void

    var thumbnailProvider: NSItemProvider?

    @State private var searchText = ""
    @State private var isSending = false
    @State private var thumbnail: NSImage?

    private let columns = [GridItem](
        repeating: GridItem(.flexible(), spacing: 12),
        count: 4
    )

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.vertical, 12)

            Divider()

            ScrollView {
                if rooms.isEmpty {
                    ContentUnavailableView(
                        "No Conversations Available",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Join a room in Relay to share content.")
                    )
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(rooms) { room in
                            RoomGridItem(room: room, isSending: isSending) {
                                guard !isSending else { return }
                                isSending = true
                                Task { await onSend(room.id) }
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.top, 10)
        }
        .frame(width: 360, height: 460)
        .task { await loadThumbnail() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("Relay")
                    .font(.headline)
                Text(attachmentCount == 1 ? "1 item" : "\(attachmentCount) items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 6))
            }
        }
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() async {
        guard let provider = thumbnailProvider else { return }

        if let item = try? await provider.loadPreviewImage(options: [:]) {
            if let nsImage = item as? NSImage {
                thumbnail = nsImage
                return
            } else if let data = item as? Data {
                thumbnail = NSImage(data: data)
                return
            }
        }

        if provider.hasItemConformingToTypeIdentifier("public.image") {
            thumbnail = await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: NSImage.self) { image, _ in
                    continuation.resume(returning: image as? NSImage)
                }
            }
        }
    }
}

// MARK: - Room Grid Item

private struct RoomGridItem: View {
    let room: ShareableRoom
    let isSending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                avatar
                    .frame(width: 48, height: 48)

                Text(room.name)
                    .font(.caption)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(isSending)
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = room.avatarData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color(stableColorFor: room.name))
                .overlay {
                    Text(initials(for: room.name))
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                }
        }
    }

    private func initials(for name: String) -> String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

