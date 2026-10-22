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

/// A single row in the message search results list.
///
/// Displays the sender name, message body with highlighted search terms,
/// and the timestamp of the matching event. Styled to match the density
/// and typography of ``RoomListRow``.
struct MessageSearchRow: View {
    @Environment(RelayClient.self) private var client
    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false
    @AppStorage(OutgoingBubbleColor.userDefaultsKey) private var outgoingBubbleColor = OutgoingBubbleColor.accent

    let result: MessageSearchResult
    let onSelect: () -> Void

    private var isOutgoing: Bool {
        guard case .loggedIn(let userId) = client.authState else { return false }
        return result.sender.value == userId
    }

    private var bubbleStyle: BubbleStyle {
        .message(
            isOutgoing: isOutgoing,
            senderID: result.sender.value,
            coloredBubbles: coloredBubbles,
            outgoingColor: outgoingBubbleColor)
    }

    var body: some View {
        let senderName = result.senderDisplayName ?? result.sender.value
        let roomName = result.roomName ?? result.roomId.value
        let timestamp = result.timestamp.formatted(date: .abbreviated, time: .shortened)

        Button(action: onSelect) {
            HStack(alignment: .bottom, spacing: 8) {
                AvatarView(
                    name: senderName,
                    mxcURL: result.senderAvatarURL?.value,
                    size: 32,
                    colorID: result.sender.value
                )
                .accessibilityHidden(true)

                Text(highlightedBody)
                    .font(.body)
                    .foregroundStyle(bubbleStyle.foregroundStyle)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BubbleStyle.horizontalPadding)
                    .padding(.vertical, BubbleStyle.verticalPadding)
                    .background(bubbleStyle.backgroundColor, in: BubbleStyle.shape)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(roomName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .help(roomName)

                    Text(result.timestamp, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: 140, alignment: .trailing)
                .layoutPriority(1)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(senderName): \(result.body), \(roomName), \(timestamp)"))
    }

    private var highlightedBody: AttributedString {
        var attributed = AttributedString(result.body)
        for highlight in result.highlights {
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let range = attributed[searchRange].range(
                of: highlight,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) {
                attributed[range].foregroundColor = bubbleStyle.usesWhiteText ? .white : (isOutgoing ? outgoingBubbleColor.foregroundColor : .primary)
                attributed[range].font = .body.bold()
                searchRange = range.upperBound..<attributed.endIndex
            }
        }
        return attributed
    }
}

// MARK: - Previews

#Preview("With Display Name") {
    Form {
        MessageSearchRow(
            result: MessageSearchResult(
                eventId: EventId(unchecked: "$evt1"),
                roomId: RoomId(unchecked: "!room:matrix.org"),
                sender: UserId(unchecked: "@alice:matrix.org"),
                senderDisplayName: "Alice",
                body: "Has anyone tried the new concurrency features in Swift 6? The structured concurrency model is really impressive.",
                timestamp: Date(timeIntervalSinceNow: -3600),
                highlights: ["concurrency", "Swift"]
            ),
            onSelect: {}
        )
    }
    .environment(PreviewFixtures.previewClient())
    .formStyle(.grouped)
    .frame(width: 500, height: 120)
}

#Preview("Without Display Name") {
    Form {
        MessageSearchRow(
            result: MessageSearchResult(
                eventId: EventId(unchecked: "$evt2"),
                roomId: RoomId(unchecked: "!room:matrix.org"),
                sender: UserId(unchecked: "@bob:matrix.org"),
                body: "The borrow checker can be tricky at first, but it prevents so many bugs at compile time.",
                timestamp: Date(timeIntervalSinceNow: -86400),
                highlights: ["borrow checker"]
            ),
            onSelect: {}
        )
    }
    .environment(PreviewFixtures.previewClient())
    .formStyle(.grouped)
    .frame(width: 500, height: 120)
}

#Preview("No Highlights") {
    Form {
        MessageSearchRow(
            result: MessageSearchResult(
                eventId: EventId(unchecked: "$evt3"),
                roomId: RoomId(unchecked: "!room:matrix.org"),
                sender: UserId(unchecked: "@carol:matrix.org"),
                senderDisplayName: "Carol",
                body: "Just pushed a fix for the memory leak in the timeline view.",
                timestamp: Date(timeIntervalSinceNow: -172800)
            ),
            onSelect: {}
        )
    }
    .environment(PreviewFixtures.previewClient())
    .formStyle(.grouped)
    .frame(width: 500, height: 120)
}
