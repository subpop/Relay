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
import MatrixKit
import SwiftUI

/// A clear-background outlined bubble showing a truncated preview of the
/// replied-to message, styled after iMessage's inline reply context.
///
/// For text messages, the bubble shows muted preview text with a thin border.
/// For image messages, a small thumbnail is shown instead. Tapping the bubble
/// scrolls the timeline to the original message.
struct ReplyPreviewBubble: View {
    /// The reply detail containing the original message's content and sender.
    let reply: ResolvedReply

    @Environment(\.timelineActions) private var actions
    @Environment(RelayClient.self) private var client

    @State private var thumbnailImage: NSImage?

    /// The size of the thumbnail in the reply preview.
    private static let thumbnailSize: CGFloat = 48

    var body: some View {
        Button {
            actions.tapReply(reply.eventID.value)
        } label: {
            if reply.imageURL != nil {
                imagePreview
            } else {
                textPreview
            }
        }
        .buttonStyle(.plain)
        .task(id: reply.imageURL) {
            guard let mxcURL = reply.imageURL else { return }
            let size = UInt64(Self.thumbnailSize * 2)
            let download = MediaFileHelper.Download(
                mxcURL: mxcURL, filename: reply.body)
            if let data = await client.mediaThumbnail(
                download, width: size, height: size
            ) {
                thumbnailImage = NSImage(data: data)
            }
        }
    }

    /// Text reply preview: muted text in an outlined bubble.
    private var textPreview: some View {
        Text(Self.replyPreviewText(reply))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, BubbleStyle.horizontalPadding)
            .padding(.vertical, BubbleStyle.verticalPadding)
            .background {
                BubbleStyle.shape
                    .strokeBorder(Color(.separatorColor), lineWidth: 1)
            }
    }

    /// Image reply preview: a small thumbnail in an outlined bubble.
    private var imagePreview: some View {
        Group {
            if let thumbnailImage {
                Image(nsImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .clipShape(BubbleStyle.shape)
                    .opacity(0.5)
            } else {
                RoundedRectangle(cornerRadius: BubbleStyle.cornerRadius, style: .continuous)
                    .fill(Color(.separatorColor).opacity(0.2))
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .overlay {
            BubbleStyle.shape
                .strokeBorder(Color(.separatorColor), lineWidth: 1)
        }
    }
}
