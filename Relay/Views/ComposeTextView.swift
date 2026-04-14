// swiftlint:disable file_length
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

// MARK: - Mention Model

/// A resolved user mention embedded in the compose text.
///
/// Each ``Mention`` tracks the Matrix user ID, the visible display name, and the
/// range within the `NSTextView`'s attributed string where the pill is rendered.
struct Mention: Identifiable, Equatable {
    let id = UUID()
    let userId: String
    let displayName: String
    /// The character range of this mention pill in the attributed string.
    var range: NSRange
}

// MARK: - Custom Attribute Key

extension NSAttributedString.Key {
    /// Custom attribute key attached to mention pill spans, storing the Matrix user ID.
    static let mentionUserId = NSAttributedString.Key("relay.mentionUserId")
}

// MARK: - ComposeTextView

/// An `NSViewRepresentable` text editor for the compose bar that supports inline
/// mention pills rendered as colored capsule backgrounds within the text.
///
/// This replaces the plain SwiftUI `TextField` to enable `NSAttributedString` editing
/// with rich mention rendering. It preserves the same UX: multi-line input, Return to
/// send, Shift+Return for newlines, and focus management.
struct ComposeTextView: NSViewRepresentable { // swiftlint:disable:this type_body_length
    /// The plain-text draft, kept in sync for message sending.
    @Binding var text: String

    /// Resolved mentions currently present in the text.
    @Binding var mentions: [Mention]

    /// The active `@`-query string when the user is typing a mention, or `nil`.
    @Binding var mentionQuery: String?

    /// Called when the user presses Return (without Shift) to send the message.
    var onSubmit: () -> Void

    /// Called when the user presses Up arrow while mention suggestions are visible.
    var onMentionNavigateUp: (() -> Void)?

    /// Called when the user presses Down arrow while mention suggestions are visible.
    var onMentionNavigateDown: (() -> Void)?

    /// Called when the user presses Tab or Return to confirm the highlighted mention suggestion.
    var onMentionConfirm: (() -> Void)?

    /// Accent color from the SwiftUI environment, used for mention pill styling.
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposeScrollView, context: Context) -> CGSize? {
        let height = nsView.intrinsicContentSize.height
        return CGSize(width: proposal.width ?? 200, height: height)
    }

    func makeNSView(context: Context) -> ComposeScrollView {
        let scrollView = ComposeScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = MentionTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.delegate = context.coordinator
        textView.mentionTextViewDelegate = context.coordinator
        textView.owningScrollView = scrollView

        // Placeholder
        textView.placeholderString = "Message"

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: ComposeScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MentionTextView else { return }

        // Keep the coordinator's reference to the parent struct current so that
        // key-handling callbacks (onMentionConfirm, etc.) and binding reads
        // (mentionQuery) reflect the latest SwiftUI state.
        context.coordinator.parent = self

        // Skip if the coordinator itself just pushed this text change to the
        // binding — the text view's storage is already correct and replacing it
        // mid-layout triggers an NSRangeException crash.
        if context.coordinator.didPushTextChange {
            context.coordinator.didPushTextChange = false
            return
        }

        // Only update text if it actually changed from outside (e.g., cleared after send)
        let currentPlainText = textView.textStorage?.string ?? ""
        if currentPlainText != text {
            context.coordinator.isUpdating = true
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]))
            // Re-apply mention styling if mentions exist
            for mention in mentions
                where mention.range.location + mention.range.length <= (textView.textStorage?.length ?? 0) {
                context.coordinator.applyMentionStyle(to: mention.range, in: textView)
                textView.textStorage?.addAttribute(.mentionUserId, value: mention.userId, range: mention.range)
            }
            context.coordinator.isUpdating = false
            textView.needsDisplay = true
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, MentionTextViewKeyDelegate {
        var parent: ComposeTextView
        weak var textView: MentionTextView?
        var isUpdating = false
        /// Tracks whether the coordinator itself just pushed a text change to
        /// the binding. When `true`, the immediately-following `updateNSView`
        /// call should skip replacing the text storage because the change
        /// originated from the text view, not from an external SwiftUI update.
        var didPushTextChange = false
        private var mentionObserver: Any?

        init(_ parent: ComposeTextView) {
            self.parent = parent
            super.init()

            // Listen for mention insertion requests from the suggestion list
            mentionObserver = NotificationCenter.default.addObserver(
                forName: .insertMention,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let userId = userInfo["userId"] as? String,
                      let displayName = userInfo["displayName"] as? String
                else { return }
                MainActor.assumeIsolated {
                    self?.insertMention(userId: userId, displayName: displayName)
                }
            }
        }

        deinit {
            MainActor.assumeIsolated {
                if let mentionObserver {
                    NotificationCenter.default.removeObserver(mentionObserver)
                }
            }
        }

        // MARK: Key Handling

        func mentionTextViewShouldConfirmOnTab(_ textView: MentionTextView) -> Bool {
            guard parent.mentionQuery != nil else { return false }
            parent.onMentionConfirm?()
            return true
        }

        func mentionTextView(_ textView: MentionTextView, shouldHandleKeyDown event: NSEvent) -> Bool {
            // Escape dismisses mention suggestions if active
            if event.keyCode == 53 && parent.mentionQuery != nil {
                parent.mentionQuery = nil
                return true
            }

            // When mention suggestions are visible, intercept navigation keys
            if parent.mentionQuery != nil {
                // Up arrow (keyCode 126) — move selection up
                if event.keyCode == 126 {
                    parent.onMentionNavigateUp?()
                    return true
                }
                // Down arrow (keyCode 125) — move selection down
                if event.keyCode == 125 {
                    parent.onMentionNavigateDown?()
                    return true
                }
                // Tab is intercepted via insertTab(_:) override, not here.
                // Return without Shift — confirm highlighted selection
                if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
                    parent.onMentionConfirm?()
                    return true
                }
            }

            // Return without Shift → send
            if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
                parent.onSubmit()
                return true
            }
            return false
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }

            let fullText = textView.textStorage?.string ?? ""
            didPushTextChange = true
            parent.text = fullText

            // Update mention ranges after text edits — remove mentions whose
            // attributed text no longer carries the mentionUserId attribute
            var updatedMentions: [Mention] = []
            guard let storage = textView.textStorage else { return }

            for mention in parent.mentions
                where mention.range.location + mention.range.length <= storage.length {
                // Check if the mention's attributed range still has the marker
                var effectiveRange = NSRange(location: 0, length: 0)
                let attr = storage.attribute(
                    .mentionUserId,
                    at: mention.range.location,
                    effectiveRange: &effectiveRange
                )
                if let userId = attr as? String, userId == mention.userId,
                   effectiveRange == mention.range {
                    updatedMentions.append(mention)
                }
            }
            parent.mentions = updatedMentions

            // Detect @mention query
            detectMentionQuery(in: textView)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            // If the edit touches a mention pill, remove the entire mention
            guard let storage = textView.textStorage else { return true }

            var mentionsToRemove: [Mention] = []
            for mention in parent.mentions
                where mention.range.location + mention.range.length <= storage.length {
                let intersection = NSIntersectionRange(affectedCharRange, mention.range)
                if intersection.length > 0 && affectedCharRange != mention.range {
                    // Partial edit into a mention — expand to delete the whole pill
                    mentionsToRemove.append(mention)
                }
            }

            if let mentionToRemove = mentionsToRemove.first {
                // Remove the entire mention pill atomically
                isUpdating = true
                textView.selectedRange = mentionToRemove.range
                textView.insertText("", replacementRange: mentionToRemove.range)
                parent.mentions.removeAll { $0.id == mentionToRemove.id }
                // Adjust remaining mention ranges
                let deletedLength = mentionToRemove.range.length
                let deletedLocation = mentionToRemove.range.location
                // swiftlint:disable:next identifier_name
                for i in parent.mentions.indices
                    where parent.mentions[i].range.location > deletedLocation {
                    parent.mentions[i].range.location -= deletedLength
                }
                parent.text = textView.textStorage?.string ?? ""
                isUpdating = false
                detectMentionQuery(in: textView)
                return false
            }

            return true
        }

        // MARK: Mention Detection

        // Character codes used for mention detection, extracted as constants
        // to avoid Xcode preview thunk literal transformation issues.
        private static let atCharCode: UInt16 = 0x40 // '@'
        private static let spaceCharCode: UInt16 = 0x20 // ' '

        private func detectMentionQuery(in textView: NSTextView) {
            let text = textView.textStorage?.string ?? ""
            let cursorLocation = textView.selectedRange().location

            guard cursorLocation > 0, cursorLocation <= text.count else {
                parent.mentionQuery = nil
                return
            }

            // Walk backward from cursor to find an unmatched '@'
            let nsText = text as NSString
            // swiftlint:disable:next identifier_name
            var i = cursorLocation - 1
            while i >= 0 {
                let char = nsText.character(at: i)

                if char == Self.atCharCode {
                    // Check that '@' is preceded by whitespace, newline, or is at position 0
                    let precededByWhitespace = i == 0
                        || CharacterSet.whitespacesAndNewlines
                            .contains(Unicode.Scalar(nsText.character(at: i - 1))!)
                    if precededByWhitespace {
                        // Make sure the cursor isn't inside an existing mention
                        let isInMention = parent.mentions.contains { NSLocationInRange(i, $0.range) }
                        if !isInMention {
                            let queryStart = i + 1
                            let queryRange = NSRange(
                                location: queryStart,
                                length: cursorLocation - queryStart
                            )
                            let query = nsText.substring(with: queryRange)
                            // Don't trigger if query contains whitespace (already completed or not a mention)
                            if !query.contains(" ") && !query.contains("\n") {
                                parent.mentionQuery = query
                                return
                            }
                        }
                    }
                    break
                }

                // Stop at whitespace/newlines — no '@' found in this word
                if let scalar = Unicode.Scalar(char), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    break
                }

                i -= 1
            }

            parent.mentionQuery = nil
        }

        // MARK: Mention Insertion

        /// Inserts a mention pill at the current `@query` position, replacing the
        /// `@query` text with a styled display name span.
        func insertMention(userId: String, displayName: String) {
            guard let textView, let storage = textView.textStorage else { return }

            let text = storage.string
            let cursorLocation = textView.selectedRange().location
            let nsText = text as NSString

            // Find the '@' that started this query
            var atIndex = cursorLocation - 1
            while atIndex >= 0 {
                if nsText.character(at: atIndex) == Self.atCharCode {
                    break
                }
                atIndex -= 1
            }

            guard atIndex >= 0 else { return }

            let replaceRange = NSRange(location: atIndex, length: cursorLocation - atIndex)
            let pillText = "@\(displayName)"
            let pillRange = NSRange(location: atIndex, length: pillText.count)

            isUpdating = true

            // Replace '@query' with the pill text
            storage.replaceCharacters(in: replaceRange, with: pillText)

            // Apply mention styling
            applyMentionStyle(to: pillRange, in: textView)
            storage.addAttribute(.mentionUserId, value: userId, range: pillRange)

            // Add a trailing space after the pill if there isn't one
            let afterPill = pillRange.location + pillRange.length
            let needsSpace = afterPill >= storage.length
                || (storage.string as NSString).character(at: afterPill) != Self.spaceCharCode
            if needsSpace {
                let spaceAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.labelColor
                ]
                storage.insert(NSAttributedString(string: " ", attributes: spaceAttrs), at: afterPill)
            }

            // Track the mention
            let lengthDelta = pillText.count - replaceRange.length
            let mention = Mention(userId: userId, displayName: displayName, range: pillRange)

            // Adjust existing mentions that come after the insertion point
            // swiftlint:disable:next identifier_name
            for i in parent.mentions.indices
                where parent.mentions[i].range.location >= atIndex {
                parent.mentions[i].range.location += lengthDelta
            }
            parent.mentions.append(mention)

            // Move cursor after the pill + space
            textView.setSelectedRange(NSRange(location: afterPill + 1, length: 0))

            parent.text = storage.string
            parent.mentionQuery = nil
            isUpdating = false
        }

        // MARK: Mention Styling

        func applyMentionStyle(to range: NSRange, in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let pillColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            storage.addAttributes([
                .backgroundColor: pillColor,
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .mentionUserId: "" // placeholder, overwritten by caller
            ], range: range)
        }
    }
}

// MARK: - MentionTextView

/// Key-handling delegate protocol for intercepting key events before `NSTextView` processes them.
protocol MentionTextViewKeyDelegate: AnyObject {
    func mentionTextView(_ textView: MentionTextView, shouldHandleKeyDown event: NSEvent) -> Bool

    /// Called when the user presses Tab. Returns `true` if the delegate handled the
    /// event (e.g. confirming a mention suggestion), preventing `NSTextView` from
    /// processing it as field navigation.
    func mentionTextViewShouldConfirmOnTab(_ textView: MentionTextView) -> Bool
}

// MARK: - ComposeScrollView

/// A scroll view that sizes itself based on the text view's content height,
/// up to a maximum, so the compose bar stays compact.
final class ComposeScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        guard let textView = documentView as? MentionTextView else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 28)
        }
        let textHeight = textView.intrinsicContentSize.height
        return NSSize(width: NSView.noIntrinsicMetric, height: textHeight)
    }
}

/// A subclass of `NSTextView` that intercepts key events (Return to send) and draws
/// a placeholder string when the text content is empty.
final class MentionTextView: NSTextView {
    weak var mentionTextViewDelegate: MentionTextViewKeyDelegate?
    weak var owningScrollView: ComposeScrollView?

    /// Placeholder text displayed when the view is empty.
    var placeholderString: String?

    override func keyDown(with event: NSEvent) {
        if mentionTextViewDelegate?.mentionTextView(self, shouldHandleKeyDown: event) == true {
            return // Event was handled (e.g. Return to send)
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        // NSTextView translates Tab into insertTab: via interpretKeyEvents.
        // Intercept it here before it inserts a literal tab character.
        if selector == #selector(insertTab(_:)),
           mentionTextViewDelegate?.mentionTextViewShouldConfirmOnTab(self) == true {
            return
        }
        super.doCommand(by: selector)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw placeholder when empty
        if string.isEmpty, let placeholder = placeholderString {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor
            ]
            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let rect = NSRect(
                x: inset.width + padding,
                y: inset.height,
                width: bounds.width - inset.width * 2 - padding * 2,
                height: bounds.height - inset.height * 2
            )
            NSAttributedString(string: placeholder, attributes: attrs).draw(in: rect)
        }
    }

    /// Guards against re-entrant `intrinsicContentSize` calls. `ensureLayout`
    /// can trigger delegate callbacks that modify the text storage and
    /// re-invalidate layout, causing a nested call with stale range data.
    private var isComputingContentSize = false

    override var intrinsicContentSize: NSSize {
        guard !isComputingContentSize,
              let container = textContainer,
              let manager = layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 22)
        }
        isComputingContentSize = true
        defer { isComputingContentSize = false }
        manager.ensureLayout(for: container)
        let usedRect = manager.usedRect(for: container)
        let inset = textContainerInset
        let height = min(max(usedRect.height + inset.height * 2, 22), 100)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.makeFirstResponder(self)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        owningScrollView?.invalidateIntrinsicContentSize()
    }
}
// MARK: - Previews

#Preview("Empty") {
    ComposeTextView(
        text: .constant(""),
        mentions: .constant([]),
        mentionQuery: .constant(nil),
        onSubmit: {}
    )
    .frame(width: 360)
    .padding()
}

#Preview("With Text") {
    ComposeTextView(
        text: .constant("Hey, have you seen the latest build?"),
        mentions: .constant([]),
        mentionQuery: .constant(nil),
        onSubmit: {}
    )
    .frame(width: 360)
    .padding()
}

#Preview("Multiline") {
    ComposeTextView(
        // swiftlint:disable:next line_length
        text: .constant("Line one\nLine two\nLine three — the text view should grow vertically to fit multiple lines of content."),
        mentions: .constant([]),
        mentionQuery: .constant(nil),
        onSubmit: {}
    )
    .frame(width: 360)
    .padding()
}

#Preview("With Mention") {
    ComposeTextView(
        text: .constant("Hey @Alice Smith check this out"),
        mentions: .constant([
            Mention(userId: "@alice:matrix.org", displayName: "Alice Smith", range: NSRange(location: 4, length: 12))
        ]),
        mentionQuery: .constant(nil),
        onSubmit: {}
    )
    .frame(width: 360)
    .padding()
}

#Preview("Active Query") {
    ComposeTextView(
        text: .constant("Hey @bo"),
        mentions: .constant([]),
        mentionQuery: .constant("bo"),
        onSubmit: {}
    )
    .frame(width: 360)
    .padding()
}
