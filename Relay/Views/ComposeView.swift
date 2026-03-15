import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Binding var text: String
    var onSend: () -> Void
    var onAttach: ([URL]) -> Void

    @FocusState private var isFocused: Bool
    @State private var isShowingFilePicker = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { isShowingFilePicker = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isFocused)
                .onSubmit {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSend()
                    }
                }
        }
        .padding(12)
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.image, .movie, .item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                onAttach(urls)
            }
        }
    }
}

#Preview("Empty") {
    ComposeView(text: .constant(""), onSend: {}, onAttach: { _ in })
        .frame(width: 400)
}

#Preview("With Text") {
    ComposeView(text: .constant("Hello, world!"), onSend: {}, onAttach: { _ in })
        .frame(width: 400)
}
