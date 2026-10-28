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
import UniformTypeIdentifiers

/// The compose bar's sticker popover: stickers from the packs the room
/// advertises, and the user's own pack with a way to add to it.
struct StickerPickerView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter

    let roomId: RoomId
    var onSelect: (ImagePackImage, String) -> Void

    @State private var model = StickerPickerViewModel()
    @State private var isImporting = false

    var body: some View {
        Group {
            if model.draft != nil {
                AddStickerForm(model: model)
            } else {
                StickerBrowser(model: model, isImporting: $isImporting, onSelect: onSelect)
            }
        }
        .frame(width: 340, height: 420)
        .task { await model.load(roomId: roomId, client: client) }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                do {
                    try model.beginDraft(fileURL: url)
                } catch {
                    errorReporter.report(.fileCopyFailed(
                        filename: url.lastPathComponent, reason: error.localizedDescription))
                }
            case .failure(let error):
                errorReporter.report(.stickerPackUpdateFailed(error.localizedDescription))
            }
        }
    }
}

/// The sticker picker's tabs.
private enum StickerPickerTab: String, CaseIterable, Identifiable {
    case mine
    case packs

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .mine: "person.crop.circle"
        case .packs: "square.grid.2x2"
        }
    }

    var label: String {
        switch self {
        case .mine: String(localized: "My Stickers", comment: "Sticker picker tab: the user's own sticker pack")
        case .packs: String(localized: "Room Packs", comment: "Sticker picker tab: sticker packs the room advertises")
        }
    }
}

/// Icon tabs for switching between sticker sources, in the style of Messages:
/// a compact centered group with a neutral highlight on the selected tab.
private struct StickerTabBar: View {
    @Binding var selection: StickerPickerTab

    var body: some View {
        HStack {
            ForEach(StickerPickerTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.title2)
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .frame(width: 64, height: 40)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                            }
                        }
                        .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help(tab.label)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The sticker tabs: the user's own pack, and the packs the room advertises.
private struct StickerBrowser: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter

    var model: StickerPickerViewModel
    @Binding var isImporting: Bool
    var onSelect: (ImagePackImage, String) -> Void

    @State private var selection = StickerPickerTab.mine

    /// Shortcode of the user's sticker awaiting removal confirmation.
    @State private var pendingRemoval: String?

    var body: some View {
        VStack(spacing: 0) {
            StickerTabBar(selection: $selection)
                .padding([.horizontal, .top])

            ScrollView {
                switch selection {
                case .mine:
                    VStack(alignment: .leading) {
                        StickerGrid(
                            entries: model.ownEntries, onSelect: onSelect,
                            onAdd: { isImporting = true },
                            onRemove: { pendingRemoval = $0 })
                        if model.ownEntries.isEmpty {
                            Text("Add images to build your own sticker pack.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }
                case .packs:
                    if model.sections.isEmpty {
                        Text("This room doesn't advertise any sticker packs.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    LazyVStack(alignment: .leading) {
                        ForEach(model.sections) { section in
                            Text(section.title)
                                .font(.headline)
                                .padding(.horizontal)
                            StickerGrid(entries: section.entries, onSelect: onSelect)
                        }
                    }
                }
            }

            if let shortcode = pendingRemoval {
                HStack {
                    Text("Remove \(shortcode) from your pack?")
                    Spacer()
                    Button("Cancel", role: .cancel) { pendingRemoval = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Remove", role: .destructive) {
                        pendingRemoval = nil
                        Task {
                            await model.remove(
                                shortcode: shortcode, client: client,
                                errorReporter: errorReporter)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
                .background(.regularMaterial)
            }

            if model.isRoomEncrypted {
                Text("Sticker images aren't encrypted, even in this encrypted room. Your homeserver can see which ones are used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .onChange(of: model.hasLoaded) {
            // A user with no stickers of their own lands on what the room offers.
            if model.ownEntries.isEmpty && !model.sections.isEmpty {
                selection = .packs
            }
        }
    }
}

/// An adaptive grid of stickers. Passing `onAdd` puts an add button first;
/// passing `onRemove` adds a trash button, shown on hover, and a Remove
/// command to each sticker's context menu.
private struct StickerGrid: View {
    var entries: [StickerPickerViewModel.Entry]
    var onSelect: (ImagePackImage, String) -> Void
    var onAdd: (() -> Void)?
    var onRemove: ((String) -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))]) {
            if let onAdd {
                Button("Add Sticker", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.15), in: .circle)
                    .frame(width: 72, height: 72)
                    .help("Add a sticker to your pack")
            }
            ForEach(entries) { entry in
                StickerCell(entry: entry, onSelect: onSelect, onRemove: onRemove)
            }
        }
        .padding(.horizontal)
    }
}

/// One sticker in a grid.
private struct StickerCell: View {
    var entry: StickerPickerViewModel.Entry
    var onSelect: (ImagePackImage, String) -> Void
    var onRemove: ((String) -> Void)?

    @State private var isHovering = false

    var body: some View {
        Button {
            onSelect(entry.image, entry.shortcode)
        } label: {
            StickerThumbnailView(image: entry.image)
                .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .help(entry.image.body ?? entry.shortcode)
        .accessibilityLabel(entry.image.body ?? entry.shortcode)
        .overlay(alignment: .topTrailing) {
            if let onRemove, isHovering {
                Button("Remove", systemImage: "trash") { onRemove(entry.shortcode) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(4)
                    .background(.regularMaterial, in: .circle)
                    .help("Remove from your pack")
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onRemove {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    onRemove(entry.shortcode)
                }
            }
        }
    }
}

/// A sticker's server-scaled thumbnail.
private struct StickerThumbnailView: View {
    @Environment(RelayClient.self) private var client

    var image: ImagePackImage

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: image.url) {
            let download = MediaFileHelper.Download(
                mxcURL: image.url, filename: image.body ?? "",
                mimetype: image.info?.mimeType, thumbnailMXCURL: image.info?.thumbnailUrl)
            if let data = await client.mediaThumbnail(download, width: 144, height: 144) {
                thumbnail = NSImage(data: data)
            }
        }
    }
}

/// The form for naming a chosen image before it joins the user's pack.
private struct AddStickerForm: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter

    @Bindable var model: StickerPickerViewModel

    var body: some View {
        if let draft = model.draft {
            // These tolerate the draft being cleared while the fields are
            // still tearing down; a `Binding` unwrapped from the optional
            // would trap on nil.
            let shortcode = Binding(
                get: { model.draft?.shortcode ?? "" }, set: { model.draft?.shortcode = $0 })
            let description = Binding(
                get: { model.draft?.body ?? "" }, set: { model.draft?.body = $0 })
            VStack {
                Image(nsImage: draft.preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 140)
                    .padding()

                Form {
                    TextField("Shortcode", text: shortcode)
                    TextField("Description", text: description, prompt: Text("Optional"))
                    switch model.draftProblem {
                    case .invalid:
                        Text("Use letters, numbers, - and _, up to 100 characters.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .duplicate:
                        Text("A sticker in your pack already uses this shortcode.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                }
                .formStyle(.grouped)
                .disabled(model.isSaving)

                if model.isSaving {
                    ProgressView(value: model.uploadProgress) {
                        Text("Uploading…")
                    }
                    .padding(.horizontal)
                }

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.draft = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isSaving)
                    Button("Add") {
                        Task { await model.saveDraft(client: client, errorReporter: errorReporter) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSaveDraft)
                }
                .padding()
            }
        }
    }
}

#Preview("Empty pack") {
    StickerPickerView(roomId: RoomId(unchecked: "!preview:matrix.org")) { _, _ in }
        .environment(RelayClient())
}

#Preview("Add sticker") {
    let model = StickerPickerViewModel()
    model.draft = StickerPickerViewModel.Draft(
        data: Data(), filename: "cat.png", mimeType: "image/png",
        preview: NSImage(systemSymbolName: "cat", accessibilityDescription: nil) ?? NSImage(),
        shortcode: "cat wave", body: "")
    return AddStickerForm(model: model)
        .environment(RelayClient())
        .frame(width: 340, height: 420)
}
