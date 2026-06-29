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
import RelayInterface

// MARK: - MessageTextContent (NSTextView subclass)

/// A read-only `NSTextView` subclass for rendering rich message text.
///
/// Provides native link hover behaviour (pointing-hand cursor and underline on
/// hover) and text selection. Designed to be extended for Matrix-specific
/// features such as mention pills and `matrix.to` links.
final class MessageTextContent: NSTextView {

    /// When `true`, `setFrameSize` will not update the text container's width.
    /// This prevents a feedback loop where SwiftUI's layout -> `setFrameSize` ->
    /// re-layout -> smaller `sizeThatFits` -> smaller frame -> repeat.
    var suppressContainerSync = false

    /// Called when the user clicks a `matrix.to` user mention link, with the Matrix user ID.
    var onUserTap: ((String) -> Void)?

    /// Called when the user clicks a `matrix.to` room link, with the room ID or alias.
    var onRoomTap: ((String) -> Void)?

    /// Timeline message for contextual actions (reply, pin, …). Set by ``MessageTextView``.
    var contextMessage: TimelineMessage?

    /// Delivers the same actions as the SwiftUI row context menu.
    var onMessageContextAction: ((TimelineRowContextAction) -> Void)?

    /// Opens the emoji reaction picker (popover host lives in ``MessageView``/``MessageBubbleContent``).
    var onPresentReactionPicker: (() -> Void)?

    /// The current user's room-level permissions for gating context menu actions.
    var permissions: RoomPermissions?

    // MARK: - Link Click Interception

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL, let uri = MatrixURI(url: url) {
            switch uri {
            case .user(let id):
                onUserTap?(id)
            case .room(let alias, _):
                onRoomTap?(alias)
            case .roomId(let id, _):
                onRoomTap?(id)
            case .event(let roomId, _, _):
                onRoomTap?(roomId)
            }
            return
        }
        super.clicked(onLink: link, at: charIndex)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // swiftlint:disable:next identifier_name
        if !suppressContainerSync, let tc = textContainer, newSize.width > 0 {
            tc.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: - Hover State

    private var isHoveringLink = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if linkRange(at: point) != nil {
            isHoveringLink = true
            NSCursor.pointingHand.set()
        } else {
            if isHoveringLink { isHoveringLink = false }
            super.mouseMoved(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringLink = false
        super.mouseExited(with: event)
    }

    func resetHoverState() {
        isHoveringLink = false
    }

    private func linkRange(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)

        let glyphIndex = layoutManager.glyphIndex(for: local, in: textContainer)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(local) else { return nil }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length else { return nil }

        var effectiveRange = NSRange()
        guard textStorage.attribute(.link, at: charIndex, effectiveRange: &effectiveRange) != nil
        else { return nil }
        return effectiveRange
    }

    // MARK: - Context Menu (merge Relay actions + system text menu)

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let baseMenu = super.menu(for: event)?.copy() as? NSMenu else {
            return super.menu(for: event)
        }

        guard let message = contextMessage, onMessageContextAction != nil else {
            return baseMenu
        }

        let entries = TimelineMessageContextMenu.entries(for: message, permissions: permissions)
        var insertIndex = 0
        for entry in entries {
            switch entry {
            case .reply:
                baseMenu.insertItem(
                    menuItem(title: "Reply", symbol: "arrowshape.turn.up.left", action: #selector(contextReply)),
                    at: insertIndex
                )
                insertIndex += 1
            case .copyMessage:
                baseMenu.insertItem(
                    menuItem(title: "Copy Message", symbol: "doc.on.doc", action: #selector(contextCopyMessage)),
                    at: insertIndex
                )
                insertIndex += 1
            case .saveMedia:
                baseMenu.insertItem(
                    menuItem(title: "Save as…", symbol: "square.and.arrow.down", action: #selector(contextSaveMedia)),
                    at: insertIndex
                )
                insertIndex += 1
            case .addReaction:
                guard onPresentReactionPicker != nil else { continue }
                baseMenu.insertItem(
                    menuItem(title: "Add Reaction…", symbol: "face.smiling", action: #selector(contextAddReaction)),
                    at: insertIndex
                )
                insertIndex += 1
            case .togglePin:
                baseMenu.insertItem(
                    menuItem(title: "Pin/Unpin", symbol: "pin", action: #selector(contextTogglePin)),
                    at: insertIndex
                )
                insertIndex += 1
            case .edit:
                baseMenu.insertItem(
                    menuItem(title: "Edit Message", symbol: "pencil", action: #selector(contextEdit)),
                    at: insertIndex
                )
                insertIndex += 1
            case .separatorBeforeDelete:
                baseMenu.insertItem(.separator(), at: insertIndex)
                insertIndex += 1
            case .delete:
                let item = menuItem(title: "Delete Message", symbol: "trash", action: #selector(contextDelete))
                item.attributedTitle = NSAttributedString(
                    string: "Delete Message",
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
                baseMenu.insertItem(item, at: insertIndex)
                insertIndex += 1
            }
        }

        if insertIndex > 0 {
            baseMenu.insertItem(.separator(), at: insertIndex)
        }

        return baseMenu
    }

    private func menuItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            item.image = img
        }
        return item
    }

    @objc private func contextReply() {
        guard let message = contextMessage else { return }
        onMessageContextAction?(.reply(message))
    }

    @objc private func contextCopyMessage() {
        guard let message = contextMessage else { return }
        onMessageContextAction?(.copy(message.body))
    }

    @objc private func contextSaveMedia() {
        guard let message = contextMessage else { return }
        onMessageContextAction?(.saveMedia(message))
    }

    @objc private func contextAddReaction() {
        onPresentReactionPicker?()
    }

    @objc private func contextTogglePin() {
        guard let message = contextMessage else { return }
        onMessageContextAction?(.togglePin(message.eventID))
    }

    @objc private func contextEdit() {
        guard let message = contextMessage else { return }
        onMessageContextAction?(.edit(message))
    }

    @objc private func contextDelete() {
        guard let message = contextMessage else { return }
        onMessageContextAction?(.delete(message))
    }
}
