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
import SwiftUI

/// Lays out the ``MessageBlock``s of one message body in a vertical stack.
///
/// Prose and table cells are rendered by the caller-supplied `textView`, so
/// the mention, link, and context-menu wiring of ``MessageTextView`` is
/// configured in one place.
struct MessageBlocksView<TextContent: View>: View {
    let blocks: [MessageBlock]

    /// Whether the bubble uses white text (an accent-colored outgoing bubble).
    let usesWhiteText: Bool

    @ViewBuilder let textView: (NSAttributedString) -> TextContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks.enumerated(), id: \.offset) { _, block in
                switch block {
                case .richText(let text):
                    textView(text)
                case .code(let code):
                    MessageCodeBlockView(block: code, usesWhiteText: usesWhiteText)
                case .table(let table):
                    MessageTableView(table: table, usesWhiteText: usesWhiteText, textView: textView)
                }
            }
        }
    }
}

// MARK: - Code Block

/// A monospaced code box that hugs short snippets and scrolls long lines
/// horizontally, with a copy button on hover.
struct MessageCodeBlockView: View {
    let block: MessageCodeBlock
    let usesWhiteText: Bool

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            MessageCodeText(code: block.code, usesWhiteText: usesWhiteText)
            ScrollView(.horizontal) {
                MessageCodeText(code: block.code, usesWhiteText: usesWhiteText)
            }
            .scrollIndicators(.automatic)
        }
        .background(usesWhiteText ? Color.black.opacity(0.2) : Color.primary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if isHovering || didCopy {
                Button(
                    didCopy ? "Copied" : "Copy",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc",
                    action: copy
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(4)
            }
        }
        .onHover { isHovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.code, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

/// The selectable monospaced text of a code block, with its inset.
private struct MessageCodeText: View {
    let code: String
    let usesWhiteText: Bool

    var body: some View {
        Text(code)
            .font(.system(size: MessageTextScale.baseFontSize, design: .monospaced))
            .foregroundStyle(usesWhiteText ? Color.white : Color.primary)
            .textSelection(.enabled)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

// MARK: - Table

/// A table rendered as a grid with aligned columns, a header divider, and
/// striped rows. Tables wider than the bubble scroll horizontally.
struct MessageTableView<TextContent: View>: View {
    let table: MessageTable
    let usesWhiteText: Bool
    let textView: (NSAttributedString) -> TextContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption = table.caption {
                textView(caption)
            }
            ViewThatFits(in: .horizontal) {
                MessageTableGrid(table: table, usesWhiteText: usesWhiteText, textView: textView)
                ScrollView(.horizontal) {
                    MessageTableGrid(table: table, usesWhiteText: usesWhiteText, textView: textView)
                }
                .scrollIndicators(.automatic)
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(usesWhiteText ? Color.white.opacity(0.3) : Color.primary.opacity(0.15))
            }
        }
    }
}

private struct MessageTableGrid<TextContent: View>: View {
    let table: MessageTable
    let usesWhiteText: Bool
    let textView: (NSAttributedString) -> TextContent

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(table.rows.enumerated(), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(row.cells.enumerated(), id: \.offset) { _, cell in
                        textView(cell.content)
                            .frame(maxWidth: .infinity, alignment: cell.alignment.frameAlignment)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(background(row: row, index: rowIndex))
                    }
                }
                if row.isHeader {
                    Divider()
                }
            }
        }
        // Size to the cells' ideal widths; the cells' flexible frames then
        // fill their column instead of claiming the whole bubble.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Header and every other body row are tinted so rows stay distinguishable.
    private func background(row: MessageTable.Row, index: Int) -> Color {
        let tint = usesWhiteText ? Color.white : Color.primary
        if row.isHeader { return tint.opacity(0.12) }
        return index.isMultiple(of: 2) ? .clear : tint.opacity(0.05)
    }
}

private extension MessageTable.Alignment {
    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
