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

import EmojiKit
import SwiftUI

/// A capsule of recently used emoji for quick reactions, with the full
/// catalog one tap away.
///
/// The recents row is an ``EmojiGrid`` over EmojiKit's persisted `.recent`
/// store. The trailing button presents ``EmojiCatalogPopover`` with the
/// recents and browsable grids. Styled as a material capsule intended to
/// float above a message bubble inside ``ReactionPickerOverlay``.
struct ReactionPickerCapsule: View {
    /// Called with the selected emoji string when the user taps an emoji.
    let onSelect: (String) -> Void

    @State private var showCatalog = false
    @State private var gridCategory: EmojiCategory?
    @State private var gridSelection: Emoji.GridSelection?

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        EmojiRecentsBootstrap.seedIfNeeded()
    }

    var body: some View {
        HStack(spacing: 0) {
            EmojiGrid(
                axis: .horizontal,
                categories: [recentCategory],
                category: $gridCategory,
                selection: $gridSelection,
                action: { onSelect($0.char) },
                sectionTitle: { $0.view },
                gridItem: { rowItem(for: $0) }
            )
            .emojiGridStyle(EmojiGridStyle(font: .title2, itemSize: 32, itemSpacing: 0, padding: 0))
            .frame(height: 32)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            Button {
                showCatalog = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCatalog) {
                EmojiCatalogPopover { emoji in
                    showCatalog = false
                    onSelect(emoji)
                }
            }
        }
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .fixedSize(horizontal: true, vertical: true)
    }

    /// The recents row content, capped to fit the capsule.
    private var recentCategory: EmojiCategory {
        .custom(
            id: "recent",
            name: "Recents",
            emojis: EmojiCategory.recent.emojis.prefix(8).map(\.char).joined(),
            iconName: "clock"
        )
    }

    private func rowItem(for params: Emoji.GridItemParameters) -> some View {
        Text(params.emoji.char)
            .font(.title2)
            .frame(width: 32, height: 32)
    }
}

/// One-time seed and migration for EmojiKit's persisted recents store.
///
/// EmojiKit's `.recent` store starts empty and uncapped, while the previous
/// implementation seeded four defaults and capped at eight rows. On first
/// run this migrates the legacy `recentEmoji` key when present, otherwise
/// writes the defaults, and caps stored recents going forward.
private enum EmojiRecentsBootstrap {
    private static let didSeedKey = "hasSeededEmojiKitRecents"
    private static let legacyKey = "recentEmoji"
    private static let defaultEmoji = ["👍", "👎", "❤️", "🤣"]
    private static let maxStored = 50

    static func seedIfNeeded() {
        let store = UserDefaults.standard
        guard !store.bool(forKey: didSeedKey) else { return }
        store.set(true, forKey: didSeedKey)
        let persisted = EmojiCategory.Persisted.recent
        persisted.setEmojisMaxCount(maxStored)
        guard persisted.getEmojis().isEmpty else { return }
        if let migrated = migratedLegacyEmoji() {
            persisted.setEmojis(migrated)
        } else {
            persisted.setEmojis(defaultEmoji.map(Emoji.init))
        }
    }

    private static func migratedLegacyEmoji() -> [Emoji]? {
        struct LegacyEntry: Decodable {
            let emoji: String
        }
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let entries = try? JSONDecoder().decode([LegacyEntry].self, from: data),
              !entries.isEmpty
        else { return nil }
        return entries.map { Emoji($0.emoji) }
    }
}

#Preview {
    ReactionPickerCapsule { emoji in
        print("Selected: \(emoji)")
    }
    .padding()
}
