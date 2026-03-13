import RelayCore
import SwiftUI

struct ComposeRoomView: View {
    @Environment(\.matrixService) private var matrixService
    @Binding var selectedRoomId: String?
    @Binding var isComposing: Bool

    @State private var query = ""
    @State private var searchResults: [DirectoryRoom] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var isJoining = false
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .onAppear { isFieldFocused = true }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Text("To:")
                .foregroundStyle(.secondary)
            TextField("Room name or alias", text: $query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onSubmit { handleSubmit() }
                .onChange(of: query) { _, newValue in
                    debounceSearch(newValue)
                }
            if isJoining {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                cancelCompose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Results

    private var resultsList: some View {
        Group {
            if let errorMessage {
                errorView(errorMessage)
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                emptyPrompt
            } else if isSearching && searchResults.isEmpty {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(searchResults) { room in
                            DirectoryRoomRow(room: room) {
                                joinRoom(idOrAlias: room.alias ?? room.roomId)
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        createRoomRow
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPrompt: some View {
        ContentUnavailableView(
            "Find or Create a Room",
            systemImage: "magnifyingglass",
            description: Text("Type a room name or alias to search the directory.")
        )
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                errorMessage = nil
                debounceSearch(query)
            }
        }
    }

    private var createRoomRow: some View {
        Button {
            createRoom()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 36, height: 36)
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    let name = query.trimmingCharacters(in: .whitespaces)
                    Text("Create \"\(name.isEmpty ? "New Room" : name)\"")
                        .fontWeight(.medium)
                    Text("Start a new private room")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search

    private func debounceSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let results = try await matrixService.searchDirectory(query: trimmed)
                guard !Task.isCancelled else { return }
                searchResults = results
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            isSearching = false
        }
    }

    // MARK: - Actions

    private func handleSubmit() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("!") {
            joinRoom(idOrAlias: trimmed)
        } else if let first = searchResults.first {
            joinRoom(idOrAlias: first.alias ?? first.roomId)
        }
    }

    private func joinRoom(idOrAlias: String) {
        guard !isJoining else { return }
        isJoining = true
        errorMessage = nil
        Task {
            do {
                try await matrixService.joinRoom(idOrAlias: idOrAlias)
                let rooms = matrixService.rooms
                if let joined = rooms.first(where: {
                    $0.id == idOrAlias || $0.name.localizedCaseInsensitiveContains(query)
                }) {
                    selectedRoomId = joined.id
                }
                isComposing = false
            } catch {
                errorMessage = error.localizedDescription
                isJoining = false
            }
        }
    }

    private func createRoom() {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isJoining else { return }
        isJoining = true
        errorMessage = nil
        Task {
            do {
                let roomId = try await matrixService.createRoom(
                    name: name,
                    topic: nil,
                    isPublic: false
                )
                selectedRoomId = roomId
                isComposing = false
            } catch {
                errorMessage = error.localizedDescription
                isJoining = false
            }
        }
    }

    private func cancelCompose() {
        searchTask?.cancel()
        isComposing = false
    }
}

// MARK: - Directory Room Row

private struct DirectoryRoomRow: View {
    let room: DirectoryRoom
    let onJoin: () -> Void

    var body: some View {
        Button(action: onJoin) {
            HStack(spacing: 10) {
                AvatarView(name: room.name ?? room.roomId, mxcURL: room.avatarURL, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name ?? room.alias ?? room.roomId)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let alias = room.alias {
                            Text(alias)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if room.memberCount > 0 {
                            Label("\(room.memberCount)", systemImage: "person.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Empty") {
    ComposeRoomView(selectedRoomId: .constant(nil), isComposing: .constant(true))
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 500, height: 400)
}
