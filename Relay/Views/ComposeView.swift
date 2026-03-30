import RelayCore
import SwiftUI
import UniformTypeIdentifiers

/// The message composition bar at the bottom of the room detail view.
///
/// ``ComposeView`` includes a text field for typing messages, an attachment button for
/// sending files and images, and an inline reply banner when replying to a specific message.
/// It uses a glass-effect background for a translucent macOS-native appearance.
struct ComposeView: View {
    /// The current draft message text, bound to the parent view's state.
    @Binding var text: String

    /// The message being replied to, or `nil` for a new message. Shows an inline reply banner.
    @Binding var replyingTo: TimelineMessage?

    /// Called when the user submits the message (presses Return).
    var onSend: () -> Void

    /// Called when the user selects files to attach via the file picker.
    var onAttach: ([URL]) -> Void

    @FocusState private var isFocused: Bool
    @State private var isShowingFilePicker = false

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 8) {
                Button { isShowingFilePicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        .glassEffect(in: .circle)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 0) {
                    if let reply = replyingTo {
                        replyBanner(reply)
                    }

                    TextField("Message", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isFocused)
                        .onSubmit {
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                onSend()
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .glassEffect(in: .rect(cornerRadius: replyingTo != nil ? 16 : 20))
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.image, .movie, .audio, .item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                onAttach(urls)
            }
        }
        .onChange(of: replyingTo) {
            if replyingTo != nil { isFocused = true }
        }
    }

    // MARK: - Reply Banner

    private func replyBanner(_ message: TimelineMessage) -> some View {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(message.displayName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Text(message.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.15)) { replyingTo = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

#Preview("Empty") {
    ComposeView(text: .constant(""), replyingTo: .constant(nil), onSend: {}, onAttach: { _ in })
        .frame(width: 400)
}

#Preview("With Text") {
    ComposeView(text: .constant("Hello, world!"), replyingTo: .constant(nil), onSend: {}, onAttach: { _ in })
        .frame(width: 400)
}

#Preview("With Long Text") {
    ComposeView(text: .constant("Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus et efficitur leo. Donec eu nunc massa. Morbi at nulla sit amet ipsum vulputate ultricies id sit amet erat. Fusce faucibus dignissim ex eget tincidunt. Donec vitae elit a tortor ultrices condimentum. Donec vitae elit a tortor ultrices condimentum. Donec vitae elit a tortor ultrices condimentum. Donec vitae elit a tortor ultrices condimentum."), replyingTo: .constant(nil), onSend: {}, onAttach: { _ in })
        .frame(width: 400)
}

#Preview("Replying") {
    ComposeView(
        text: .constant(""),
        replyingTo: .constant(TimelineMessage(
            id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
            body: "Nice, rooms are loading way faster now.",
            timestamp: .now, isOutgoing: false
        )),
        onSend: {},
        onAttach: { _ in }
    )
    .frame(width: 400)
}
