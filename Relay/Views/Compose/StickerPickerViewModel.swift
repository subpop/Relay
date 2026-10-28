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
import Observation
import UniformTypeIdentifiers

/// State behind the sticker picker popover: the stickers a room offers, the
/// user's own pack, and the flow for adding an image to that pack.
@Observable
final class StickerPickerViewModel {
    /// One sticker in a pack, identified by its shortcode.
    struct Entry: Identifiable, Hashable {
        var shortcode: String
        var image: ImagePackImage

        var id: String { shortcode }
    }

    /// A pack's stickers under its title.
    struct PackSection: Identifiable, Hashable {
        var id: String
        var title: String
        var entries: [Entry]
    }

    /// An image chosen for the user's pack, awaiting a shortcode and upload.
    struct Draft {
        var data: Data
        var filename: String
        var mimeType: String
        var preview: NSImage
        var shortcode: String
        var body = ""
    }

    /// Why a chosen file can't become a sticker.
    enum DraftError: LocalizedError {
        case notAnImage

        var errorDescription: String? {
            String(localized: "The selected file isn't a supported image.", comment: "Error message: the file chosen as a sticker isn't an image")
        }
    }

    /// The user's own stickers.
    private(set) var ownEntries: [Entry] = []

    /// Packs the room advertises, in priority order, with sticker content only.
    private(set) var sections: [PackSection] = []

    /// Whether the room is end-to-end encrypted, where pack images still
    /// travel unencrypted.
    private(set) var isRoomEncrypted = false

    /// The image being added to the user's pack, if the add form is open.
    var draft: Draft?

    private(set) var isSaving = false

    /// How much of the draft's upload has been sent (0 to 1), or nil before
    /// the upload reports progress and while nothing is uploading.
    private(set) var uploadProgress: Double?

    /// Whether the first load has finished.
    private(set) var hasLoaded = false

    /// What's wrong with the draft's shortcode, if anything.
    var draftProblem: StickerPackEditing.ShortcodeProblem? {
        guard let draft else { return nil }
        return StickerPackEditing.problem(
            with: draft.shortcode, existing: Set(ownEntries.map(\.shortcode)))
    }

    var canSaveDraft: Bool {
        draft != nil && draftProblem == nil && !isSaving
    }

    func load(roomId: RoomId, client: RelayClient) async {
        ownEntries = Self.entries(of: client.ownStickerPack())
        isRoomEncrypted = client.rooms.first { $0.roomId == roomId }?.isEncrypted == true
        sections = Self.sections(from: await client.imagePacks(for: roomId))
        hasLoaded = true
    }

    /// Opens the add form for the image at `url`.
    func beginDraft(fileURL url: URL) throws {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
            let mimeType = type.preferredMIMEType, let preview = NSImage(data: data)
        else { throw DraftError.notAnImage }
        draft = Draft(
            data: data, filename: url.lastPathComponent, mimeType: mimeType, preview: preview,
            shortcode: StickerPackEditing.suggestedShortcode(
                fromFilename: url.lastPathComponent, avoiding: Set(ownEntries.map(\.shortcode))))
    }

    /// Uploads the draft and adds it to the user's pack.
    func saveDraft(client: RelayClient, errorReporter: ErrorReporter) async {
        guard let draft, canSaveDraft else { return }
        isSaving = true
        defer {
            isSaving = false
            uploadProgress = nil
        }
        do {
            let pack = try await client.addOwnSticker(
                data: draft.data, mimeType: draft.mimeType, filename: draft.filename,
                shortcode: draft.shortcode,
                body: draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
            ) { [weak self] fraction in
                Task { @MainActor in
                    // A late update must not outlive the save it belongs to.
                    if self?.isSaving == true { self?.uploadProgress = fraction }
                }
            }
            ownEntries = Self.entries(of: pack)
            self.draft = nil
        } catch {
            errorReporter.report(.stickerPackUpdateFailed(error.localizedDescription))
        }
    }

    /// Removes a sticker from the user's pack.
    func remove(shortcode: String, client: RelayClient, errorReporter: ErrorReporter) async {
        do {
            ownEntries = Self.entries(of: try await client.removeOwnSticker(shortcode: shortcode))
        } catch {
            errorReporter.report(.stickerPackUpdateFailed(error.localizedDescription))
        }
    }

    // MARK: - Building Sections

    /// A pack's stickers, ordered by shortcode.
    static func entries(of content: ImagePackContent) -> [Entry] {
        content.images
            .map { Entry(shortcode: $0.key, image: $0.value) }
            .sorted { $0.shortcode.localizedStandardCompare($1.shortcode) == .orderedAscending }
    }

    /// The packs that offer stickers and have some, titled by their display
    /// name, then their state key.
    static func sections(from packs: [ImagePack]) -> [PackSection] {
        packs.filter { $0.supports(.sticker) }.compactMap { pack in
            let entries = entries(of: pack.content)
            guard !entries.isEmpty else { return nil }
            let title =
                if let name = pack.displayName, !name.isEmpty { name }
                else if !pack.stateKey.isEmpty { pack.stateKey }
                else { String(localized: "Stickers", comment: "Title of a sticker pack that has no name, and the label of the compose bar's plus-menu row that opens the sticker picker") }
            return PackSection(id: pack.id, title: title, entries: entries)
        }
    }
}
