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

/// An `NSViewRepresentable` wrapping an `NSTextView` with inline mention pill support.
///
/// ``ComposeTextView`` hosts ``PillTextAttachment`` pills rendered as
/// static images (SwiftUI ``MentionPillView`` snapshots). It supports:
/// - Return to send, Option+Return for newline
/// - Arrow key / Tab / Escape navigation for mention suggestions
/// - Atomic deletion of pill attachments
/// - Auto-sizing height (1–5 lines, scrollable beyond)
/// - Placeholder text when empty
///
/// Height is reported via the `onHeightChange` callback after every text
/// edit. The parent view should use `.frame(height:)` to size this view.
struct ComposeTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var mentionQuery: String?
    /// Set by the representable on creation; the owner can call this closure
    /// to insert a mention pill at the current `@query` position.
    @Binding var insertMentionHandler: ((_ userId: String, _ displayName: String) -> Void)?
    var onSubmit: () -> Void
    var onHeightChange: ((CGFloat) -> Void)?
    var onMentionNavigateUp: (() -> Void)?
    var onMentionNavigateDown: (() -> Void)?
    var onMentionConfirm: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ComposeScrollView {
        // Use the default NSTextView initializer which creates a TextKit 2 stack
        // (NSTextLayoutManager). This enables NSTextAttachmentViewProvider support
        // for rendering live SwiftUI pill views inline.
        let textView = ComposeInputTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.textColor,
        ]
        textView.placeholderString = "Message"
        textView.delegate = context.coordinator
        textView.keyDelegate = context.coordinator

        let scrollView = ComposeScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.linkedTextView = textView

        context.coordinator.textView = textView

        // Expose the mention insertion closure to the parent view.
        // Deferred to next main actor turn to avoid modifying state during view update.
        let coordinator = context.coordinator
        let heightCallback = onHeightChange
        let initialHeight = textView.cachedHeight
        Task { @MainActor in
            self.insertMentionHandler = { [weak coordinator] userId, displayName in
                coordinator?.insertMention(userId: userId, displayName: displayName)
            }
            heightCallback?(initialHeight)
        }

        // Restore spell check preferences.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "relay.continuousSpellChecking") != nil {
            textView.isContinuousSpellCheckingEnabled = defaults.bool(forKey: "relay.continuousSpellChecking")
        }
        if defaults.object(forKey: "relay.grammarChecking") != nil {
            textView.isGrammarCheckingEnabled = defaults.bool(forKey: "relay.grammarChecking")
        }

        return scrollView
    }

    func updateNSView(_ scrollView: ComposeScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = scrollView.linkedTextView else { return }
        guard !context.coordinator.didPushTextChange else {
            context.coordinator.didPushTextChange = false
            return
        }

        // Only update if the plain text actually differs (e.g. cleared after send).
        let currentPlain = context.coordinator.plainText(from: textView.textStorage!)
        if currentPlain != text {
            let storage = textView.textStorage!
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            storage.setAttributes(textView.typingAttributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            textView.recalculateHeight()
            // Defer to the next main actor turn to avoid
            // "Modifying state during view update".
            let height = textView.cachedHeight
            let callback = onHeightChange
            Task { @MainActor in
                callback?(height)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, ComposeInputKeyDelegate {
        var parent: ComposeTextView
        weak var textView: ComposeInputTextView?

        /// Set to `true` when the coordinator pushes a text change to prevent
        /// `updateNSView` from re-setting the text storage (avoiding crashes).
        var didPushTextChange = false

        init(parent: ComposeTextView) {
            self.parent = parent
        }

        // MARK: - Plain Text Extraction

        /// Extracts plain text from the text storage, replacing pill attachments
        /// with their user ID.
        func plainText(from storage: NSTextStorage) -> String {
            var result = ""
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                if let attachment = attrs[.attachment] as? PillTextAttachment {
                    result += attachment.userId
                } else {
                    result += (storage.string as NSString).substring(with: range)
                }
            }
            return result
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let storage = textView.textStorage!

            // Reset typing attributes after a pill so subsequent typing is plain.
            textView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.textColor,
            ]

            // Sync plain text to the binding.
            didPushTextChange = true
            parent.text = plainText(from: storage)

            // Detect mention query based on cursor position.
            let cursorPosition = textView.selectedRange().location
            detectMentionQuery(in: storage, cursorPosition: cursorPosition)

            textView.recalculateHeight()
            parent.onHeightChange?(textView.cachedHeight)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let storage = textView.textStorage else { return true }

            // Check if the edit touches a pill attachment — if so, delete the whole pill.
            var pillRange: NSRange?
            storage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                guard value is PillTextAttachment else { return }
                let intersection = NSIntersectionRange(affectedCharRange, range)
                if intersection.length > 0 {
                    pillRange = range
                    stop.pointee = true
                }
            }

            if let pillRange, affectedCharRange != pillRange {
                // The user is trying to partially edit a pill — delete the whole pill instead.
                storage.beginEditing()
                storage.replaceCharacters(in: pillRange, with: "")
                storage.endEditing()
                textView.setSelectedRange(NSRange(location: pillRange.location, length: 0))
                textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                return false
            }

            return true
        }

        // MARK: - Key Handling

        func composeTextView(_ textView: ComposeInputTextView, shouldHandleKeyDown event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Return key handling
            if event.keyCode == 36 { // Return
                if flags.contains(.option) {
                    // Option+Return → insert newline
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if parent.mentionQuery != nil {
                    // Return with mention popup → confirm selection
                    parent.onMentionConfirm?()
                    return true
                }
                // Plain Return → send
                parent.onSubmit()
                return true
            }

            // Escape → dismiss mention popup
            if event.keyCode == 53 {
                if parent.mentionQuery != nil {
                    parent.mentionQuery = nil
                    return true
                }
                return false
            }

            // Arrow keys for mention navigation
            if parent.mentionQuery != nil {
                if event.keyCode == 126 { // Up arrow
                    parent.onMentionNavigateUp?()
                    return true
                }
                if event.keyCode == 125 { // Down arrow
                    parent.onMentionNavigateDown?()
                    return true
                }
            }

            return false
        }

        func composeTextViewShouldConfirmOnTab(_ textView: ComposeInputTextView) -> Bool {
            if parent.mentionQuery != nil {
                parent.onMentionConfirm?()
                return true
            }
            return false
        }

        // MARK: - Mention Query Detection

        /// Walks backward from the cursor looking for `@` preceded by whitespace
        /// or start-of-string, then sets `mentionQuery` to the text between `@` and cursor.
        private func detectMentionQuery(in storage: NSTextStorage, cursorPosition: Int) {
            guard cursorPosition > 0 else {
                parent.mentionQuery = nil
                return
            }

            let string = storage.string as NSString

            // Walk backward from cursor to find '@'
            var i = cursorPosition - 1
            while i >= 0 {
                let char = string.character(at: i)
                guard let scalar = Unicode.Scalar(char) else { i -= 1; continue }

                // If we hit whitespace or newline before finding '@', no mention
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    parent.mentionQuery = nil
                    return
                }

                if scalar == "@" {
                    // '@' must be at start or preceded by whitespace
                    let precededBySpace = i == 0 || {
                        guard let prev = Unicode.Scalar(string.character(at: i - 1)) else { return false }
                        return CharacterSet.whitespacesAndNewlines.contains(prev)
                    }()
                    if precededBySpace {
                        // Check the '@' isn't inside a pill attachment
                        var insidePill = false
                        storage.enumerateAttribute(
                            .attachment,
                            in: NSRange(location: i, length: 1)
                        ) { value, _, _ in
                            if value is PillTextAttachment { insidePill = true }
                        }
                        if insidePill {
                            parent.mentionQuery = nil
                            return
                        }

                        let queryStart = i + 1
                        let query = string.substring(
                            with: NSRange(location: queryStart, length: cursorPosition - queryStart)
                        )
                        parent.mentionQuery = query
                        return
                    }
                    // '@' not preceded by whitespace — not a mention trigger
                    parent.mentionQuery = nil
                    return
                }

                i -= 1
            }

            parent.mentionQuery = nil
        }

        // MARK: - Mention Insertion

        /// Inserts a mention pill at the current `@query` position.
        ///
        /// Replaces the `@query` text with a ``PillTextAttachment`` character
        /// that renders as an inline pill. Adds `.mentionUserID` and
        /// `.mentionDisplayName` attributes for later extraction.
        func insertMention(userId: String, displayName: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let nsString = storage.string as NSString
            let cursorPosition = textView.selectedRange().location

            // Find the '@' that started this query by walking backward from cursor.
            var atIndex: Int?
            var i = cursorPosition - 1
            while i >= 0 {
                let char = nsString.character(at: i)
                guard let scalar = Unicode.Scalar(char) else { i -= 1; continue }
                if scalar == "@" {
                    let precededBySpace = i == 0 || {
                        guard let prev = Unicode.Scalar(nsString.character(at: i - 1)) else { return false }
                        return CharacterSet.whitespacesAndNewlines.contains(prev)
                    }()
                    if precededBySpace {
                        atIndex = i
                    }
                    break
                }
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    break
                }
                i -= 1
            }

            guard let atIndex else { return }
            let replaceRange = NSRange(location: atIndex, length: cursorPosition - atIndex)

            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let attachment = PillTextAttachment(userId: userId, displayName: displayName, font: font)

            let attachmentString = NSMutableAttributedString(attachment: attachment)
            attachmentString.addAttributes([
                .mentionUserID: userId,
                .mentionDisplayName: displayName,
                .font: font,
                .foregroundColor: NSColor.textColor,
            ], range: NSRange(location: 0, length: attachmentString.length))

            // Add a trailing space so the user can continue typing.
            let trailing = NSAttributedString(string: " ", attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor,
            ])

            let replacement = NSMutableAttributedString()
            replacement.append(attachmentString)
            replacement.append(trailing)

            storage.beginEditing()
            storage.replaceCharacters(in: replaceRange, with: replacement)
            storage.endEditing()

            let newCursor = atIndex + replacement.length
            textView.setSelectedRange(NSRange(location: newCursor, length: 0))

            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }
    }
}

// MARK: - Key Delegate Protocol

/// Protocol for intercepting key events in the compose text view.
protocol ComposeInputKeyDelegate: AnyObject {
    func composeTextView(_ textView: ComposeInputTextView, shouldHandleKeyDown event: NSEvent) -> Bool
    func composeTextViewShouldConfirmOnTab(_ textView: ComposeInputTextView) -> Bool
}

// MARK: - ComposeScrollView

/// A scroll view that reports its intrinsic content size based on the text view's height.
final class ComposeScrollView: NSScrollView {
    weak var linkedTextView: ComposeInputTextView?

    override var intrinsicContentSize: NSSize {
        guard let textView = linkedTextView else { return super.intrinsicContentSize }
        return textView.intrinsicContentSize
    }
}

// MARK: - ComposeInputTextView

/// An `NSTextView` subclass for the compose bar with key interception,
/// placeholder drawing, and auto-sizing.
final class ComposeInputTextView: NSTextView {
    weak var keyDelegate: ComposeInputKeyDelegate?
    var placeholderString: String?

    /// Cached content height, updated after every text change.
    /// Initialized to a sensible single-line height (lineHeight + insets).
    private(set) var cachedHeight: CGFloat = NSFont.systemFontSize * 1.2 + 20
    private var isRecalculatingHeight = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: cachedHeight)
    }

    /// Recomputes the content height from the current layout and invalidates
    /// intrinsic content size so SwiftUI picks up the change.
    func recalculateHeight() {
        guard !isRecalculatingHeight else { return }
        isRecalculatingHeight = true
        defer { isRecalculatingHeight = false }

        let insets = textContainerInset
        let lineHeight = (font ?? .systemFont(ofSize: NSFont.systemFontSize)).pointSize * 1.2
        let minHeight = lineHeight + insets.height * 2
        let maxHeight = lineHeight * 5 + insets.height * 2

        let usedHeight: CGFloat
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            usedHeight = layoutManager.usedRect(for: textContainer).height
        } else {
            usedHeight = 0
        }

        let newHeight = min(max(usedHeight + insets.height * 2, minHeight), maxHeight)
        guard newHeight != cachedHeight else { return }
        cachedHeight = newHeight
        invalidateIntrinsicContentSize()
        (enclosingScrollView as? ComposeScrollView)?.invalidateIntrinsicContentSize()
    }

    override func didChangeText() {
        super.didChangeText()
        recalculateHeight()
    }

    override func keyDown(with event: NSEvent) {
        if let keyDelegate, keyDelegate.composeTextView(self, shouldHandleKeyDown: event) {
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertTab(_:)) {
            if let keyDelegate, keyDelegate.composeTextViewShouldConfirmOnTab(self) {
                return
            }
        }
        super.doCommand(by: selector)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw placeholder when empty.
        if string.isEmpty, let placeholder = placeholderString {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
            let insets = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let origin = NSPoint(x: insets.width + padding, y: insets.height)
            (placeholder as NSString).draw(at: origin, withAttributes: attrs)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    // Persist spell check preferences since the app isn't NSDocument-based.
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        UserDefaults.standard.set(isContinuousSpellCheckingEnabled, forKey: "relay.continuousSpellChecking")
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        super.toggleGrammarChecking(sender)
        UserDefaults.standard.set(isGrammarCheckingEnabled, forKey: "relay.grammarChecking")
    }
}
