import AppKit
import SwiftUI

struct EmojiPickerPopover: View {
    let onSelect: (String) -> Void

    @State private var openCharacterPalette = false

    private static let emoji: [[String]] = [
        ["👍", "👎", "❤️", "😂", "🎉"],
        ["😮", "🙏", "👀", "🔥", "✨"],
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Self.emoji, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { e in
                        EmojiCell(emoji: e) { onSelect(e) }
                    }
                }
            }

            Divider()

            Button {
                openCharacterPalette = true
            } label: {
                Label("Emoji & Symbols", systemImage: "character.book.closed")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background {
            EmojiCaptureField(activate: $openCharacterPalette) { text in
                onSelect(text)
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
    }
}

// MARK: - Character Palette Capture

private struct EmojiCaptureField: NSViewRepresentable {
    @Binding var activate: Bool
    var onInput: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.stringValue = ""
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onInput = onInput
        if activate {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
                NSApp.orderFrontCharacterPalette(nil)
                activate = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onInput: (String) -> Void

        init(onInput: @escaping (String) -> Void) {
            self.onInput = onInput
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                onInput(text)
                field.stringValue = ""
            }
        }
    }
}

private struct EmojiCell: View {
    let emoji: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    EmojiPickerPopover { emoji in
        print("Selected: \(emoji)")
    }
}
