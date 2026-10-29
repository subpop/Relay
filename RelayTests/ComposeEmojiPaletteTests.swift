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
import Testing

@testable import Relay

/// Opening the system emoji picker from the compose bar.
@MainActor
@Suite
struct ComposeEmojiPaletteTests {
    /// A window whose key state the test controls.
    private final class TestWindow: NSWindow {
        var isKey = false
        override var isKeyWindow: Bool { isKey }
    }

    /// Hosts the real compose field in a window and returns it with its
    /// coordinator, whose "open the picker" action is replaced by `present`.
    private func field(
        for compose: ComposeViewModel, in window: NSWindow?, present: @escaping () -> Void
    ) throws -> (view: ComposeInputTextView, coordinator: ComposeTextView.Coordinator) {
        let bindable = Bindable(compose)
        let host = NSHostingView(
            rootView: ComposeTextView(
                text: bindable.text,
                mentionQuery: bindable.mentionQuery,
                insertMentionHandler: bindable.insertMentionHandler,
                showEmojiPaletteHandler: bindable.showEmojiPaletteHandler,
                onSubmit: {},
                shouldFocus: bindable.shouldFocusTextField))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        window?.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(host.firstDescendant(of: ComposeInputTextView.self))
        let coordinator = try #require(view.delegate as? ComposeTextView.Coordinator)
        coordinator.presentEmojiPalette = present
        return (view, coordinator)
    }

    private func makeWindow() -> TestWindow {
        let window = TestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aKeyWindowFocusesTheFieldAndOpensThePicker() throws {
        let window = makeWindow()
        window.isKey = true
        var presented = 0
        let compose = ComposeViewModel()
        let field = try field(for: compose, in: window) { presented += 1 }

        compose.showEmojiPalette()

        #expect(presented == 1)
        #expect(window.firstResponder === field.view)
    }

    @Test func aWindowThatIsNotKeyYetWaitsForIt() async throws {
        let window = makeWindow()
        var presented = 0
        let compose = ComposeViewModel()
        let field = try field(for: compose, in: window) { presented += 1 }

        compose.showEmojiPalette()
        #expect(presented == 0)

        // The plus menu's popover finishes closing and the window takes focus back.
        window.isKey = true
        await withCheckedContinuation { continuation in
            field.coordinator.presentEmojiPalette = {
                presented += 1
                continuation.resume()
            }
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
        #expect(presented == 1)
        #expect(window.firstResponder === field.view)
    }

    @Test func askingTwiceStillOpensThePickerOnce() async throws {
        let window = makeWindow()
        var presented = 0
        let compose = ComposeViewModel()
        let field = try field(for: compose, in: window) { presented += 1 }

        compose.showEmojiPalette()
        compose.showEmojiPalette()
        window.isKey = true
        await withCheckedContinuation { continuation in
            field.coordinator.presentEmojiPalette = {
                presented += 1
                continuation.resume()
            }
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
        // Let any second observer run before checking.
        for _ in 0..<5 { await Task.yield() }
        #expect(presented == 1)
    }

    @Test func doesNothingWithoutAWindow() throws {
        var presented = 0
        let compose = ComposeViewModel()
        _ = try field(for: compose, in: nil) { presented += 1 }
        compose.showEmojiPalette()
        #expect(presented == 0)
    }

    @Test func doesNothingBeforeTheFieldExists() {
        ComposeViewModel().showEmojiPalette()
    }
}

private extension NSView {
    /// The first view of type `T` in this view's subtree, depth first.
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
