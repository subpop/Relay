import RelayCore
import SwiftUI

struct MessageView: View {
    let message: TimelineMessage
    var isLastInGroup: Bool = true
    var showSenderName: Bool = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isOutgoing {
                Spacer(minLength: 60)
            }

            if !message.isOutgoing {
                if isLastInGroup {
                    AvatarView(
                        name: message.displayName,
                        mxcURL: message.senderAvatarURL,
                        size: 28
                    )
                } else {
                    Spacer()
                        .frame(width: 28)
                }
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 1) {
                if showSenderName && !message.isOutgoing {
                    Text(message.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .padding(.bottom, 2)
                }

                Text(message.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
            }

            if !message.isOutgoing {
                Spacer(minLength: 60)
            }
        }
    }

    private var bubbleColor: Color {
        message.isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2)
    }
}

#Preview {
    VStack(spacing: 2) {
        MessageView(
            message: TimelineMessage(
                id: "1",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice",
                body: "Hey, how's it going?",
                timestamp: .now.addingTimeInterval(-120),
                isOutgoing: false
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "1b",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice",
                body: "Haven't seen you in a while!",
                timestamp: .now.addingTimeInterval(-110),
                isOutgoing: false
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "2",
                senderID: "@me:matrix.org",
                senderDisplayName: nil,
                body: "Pretty good! Working on the app.",
                timestamp: .now.addingTimeInterval(-60),
                isOutgoing: true
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "3",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice",
                body: "Nice — let me know when it's ready to test. I've been looking forward to trying a new Matrix client.",
                timestamp: .now,
                isOutgoing: false
            ),
            showSenderName: true
        )
    }
    .padding()
    .frame(width: 500)
}
