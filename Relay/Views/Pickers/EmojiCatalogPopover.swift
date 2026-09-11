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

/// The full emoji catalog presented from ``ReactionPickerCapsule``.
///
/// A single grid with the persisted `.recent` category on top followed by
/// the standard categories, plus a search field. A floating liquid glass
/// capsule at the bottom jumps to each category. Any tap flows through
/// `onSelect` as a plain string, matching the capsule's quick-pick path.
struct EmojiCatalogPopover: View {
    /// Called with the selected emoji string when the user taps an emoji.
    let onSelect: (String) -> Void

    @State private var searchText = ""
    @State private var gridCategory: EmojiCategory?
    @State private var gridSelection: Emoji.GridSelection?

    var body: some View {
        EmojiGridScrollView(
            categories: catalogCategories,
            category: $gridCategory,
            selection: $gridSelection,
            query: searchText,
            action: { onSelect($0.char) },
            sectionTitle: { $0.view },
            gridItem: { $0.view }
        )
        // Fresh scroll state when entering/leaving search so results
        // start at the top. Keyed on emptiness rather than the query
        // itself, so typing never rebuilds the search field out from
        // under the cursor.
        .id(searchText.isEmpty)
        .safeAreaInset(edge: .top, spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            categoryCapsule
                .padding(.bottom, 8)
        }
        .frame(width: 360, height: 430)
    }

    /// Recents first, then the standard categories. A non-empty search
    /// query overrides this inside the grid with a global search result.
    /// Empty categories (e.g. recents before first use) are dropped by
    /// the grid automatically.
    private var catalogCategories: [EmojiCategory] {
        let standard: [EmojiCategory] = .standard
        return [.recent] + standard
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var categoryCapsule: some View {
        HStack(spacing: 2) {
            ForEach(catalogCategories, id: \.id) { category in
                let isSelected = gridCategory?.id == category.id
                Button {
                    searchText = ""
                    gridCategory = category
                } label: {
                    Label(category.labelText, systemImage: category.symbolIconName)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(isSelected ? Color.primary.opacity(0.12) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(category.labelText)
            }
        }
        .padding(6)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

#Preview {
    EmojiCatalogPopover { emoji in
        print("Selected: \(emoji)")
    }
    .padding()
}
