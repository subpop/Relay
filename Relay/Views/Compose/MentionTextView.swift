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

    // MARK: - Persisting spell-check / grammar-check preferences

    // NSTextView auto-persists these settings only in NSDocument-based apps.
    // Since we create the text view manually inside NSViewRepresentable, we
    // override the toggle actions to save the resulting state to UserDefaults.

    static let continuousSpellCheckingKey = "compose.continuousSpellChecking"
    static let grammarCheckingKey = "compose.grammarChecking"

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        UserDefaults.standard.set(isContinuousSpellCheckingEnabled, forKey: Self.continuousSpellCheckingKey)
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        super.toggleGrammarChecking(sender)
        UserDefaults.standard.set(isGrammarCheckingEnabled, forKey: Self.grammarCheckingKey)
    }
}
