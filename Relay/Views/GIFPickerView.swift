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

import RelayInterface
import SwiftUI

/// A popover view for searching and selecting animated GIFs.
///
/// Shows trending GIFs by default and switches to search results as the user
/// types. Results are displayed in a grid with infinite scroll pagination.
/// Includes required provider attribution at the bottom.
struct GIFPickerView: View {
    @Environment(\.gifSearchService) private var gifSearchService

    /// Called when the user selects a GIF from the grid.
    let onSelect: (GIFSearchResult) -> Void

    @State private var query = ""
    @State private var results: [GIFSearchResult] = []
    @State private var isLoading = false
    @State private var hasMoreResults = true
    @State private var currentOffset = 0
    @State private var searchTask: Task<Void, Never>?

    private let pageSize = 25

    private let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 4),
    ]

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            gifGrid
            Divider()
            attribution
        }
        .frame(width: 400, height: 480)
        .task {
            await loadTrending()
        }
        .onChange(of: query) {
            // Debounce search by cancelling previous task
            searchTask?.cancel()
            searchTask = Task {
                // Wait 300ms before searching to avoid excessive API calls
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                currentOffset = 0
                hasMoreResults = true

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await loadTrending()
                } else {
                    await performSearch()
                }
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search GIFs", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - GIF Grid

    private var gifGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(results) { gif in
                    GIFGridCell(gif: gif) {
                        onSelect(gif)
                        // Fire click analytics
                        if let url = gif.onclickURL {
                            Task { await gifSearchService.registerAction(url: url) }
                        }
                    }
                    .onAppear {
                        // Fire view analytics for the first appearance
                        if let url = gif.onloadURL {
                            Task { await gifSearchService.registerAction(url: url) }
                        }
                        // Pagination: load more when the last item appears
                        if gif.id == results.last?.id, hasMoreResults, !isLoading {
                            Task { await loadNextPage() }
                        }
                    }
                }
            }
            .padding(4)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Attribution

    private var attribution: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Powered by GIPHY")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Image("GiphyLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 14)
                .opacity(0.6)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Data Loading

    private func loadTrending() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let gifs = try await gifSearchService.trending(offset: 0, limit: pageSize)
            results = gifs
            currentOffset = gifs.count
            hasMoreResults = gifs.count >= pageSize
        } catch {
            results = []
        }
    }

    private func performSearch() async {
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let gifs = try await gifSearchService.search(query: searchQuery, offset: 0, limit: pageSize)
            results = gifs
            currentOffset = gifs.count
            hasMoreResults = gifs.count >= pageSize
        } catch {
            results = []
        }
    }

    private func loadNextPage() async {
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        isLoading = true
        defer { isLoading = false }

        do {
            let gifs: [GIFSearchResult]
            if searchQuery.isEmpty {
                gifs = try await gifSearchService.trending(offset: currentOffset, limit: pageSize)
            } else {
                gifs = try await gifSearchService.search(query: searchQuery, offset: currentOffset, limit: pageSize)
            }

            results.append(contentsOf: gifs)
            currentOffset += gifs.count
            hasMoreResults = gifs.count >= pageSize
        } catch {
            hasMoreResults = false
        }
    }
}

// MARK: - Grid Cell

/// A single cell in the GIF picker grid, displaying a GIF preview.
private struct GIFGridCell: View {
    let gif: GIFSearchResult
    let action: () -> Void

    @State private var isHovering = false

    /// Computes the display height for this cell based on its aspect ratio,
    /// maintaining the original proportions within the grid column width.
    private var aspectRatio: CGFloat {
        guard gif.previewSize.height > 0 else { return 1 }
        return gif.previewSize.width / gif.previewSize.height
    }

    var body: some View {
        Button(action: action) {
            AsyncAnimatedImageView(url: gif.previewURL, isAnimating: true)
                .aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if isHovering, let username = gif.username, !username.isEmpty {
                    Text(username)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(4)
                        .transition(.opacity)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(isHovering ? 0.4 : 0), lineWidth: 2)
            )
            .scaleEffect(isHovering ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(gif.altText ?? gif.title)
    }

}

// MARK: - Previews

#Preview("GIF Picker") {
    GIFPickerView { gif in
        print("Selected: \(gif.title)")
    }
    .environment(\.gifSearchService, PreviewGIFSearchService())
}
