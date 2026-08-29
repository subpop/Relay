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
import SwiftUI

// MARK: - MessageTextView (NSViewRepresentable)

/// SwiftUI wrapper around ``MessageTextContent`` for rendering rich message
/// text with proper link hover behaviour, text selection, and layout sizing.
///
/// Accepts a single `NSAttributedString` representing the parsed message body
/// (either from ``NSAttributedString/init(matrixHTML:)`` or
/// ``NSAttributedString/init(matrixMarkdown:)``). Color overrides for the
/// current bubble style are applied at render time.
struct MessageTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let isOutgoing: Bool

    /// Called when the user clicks a `matrix.to` user mention link, with the Matrix user ID.
    var onUserTap: ((String) -> Void)?

    /// Called when the user clicks a `matrix.to` room link, with the room ID or alias.
    var onRoomTap: ((String) -> Void)?

    /// When set with ``contextMessage`` and ``onMessageContextAction``, right-click merges Relay actions into the text menu.
    var contextMessage: TimelineMessage?

    var onMessageContextAction: ((TimelineRowContextAction) -> Void)?

    var onPresentReactionPicker: (() -> Void)?

    /// The current user's room-level permissions for gating context menu actions.
    var permissions: RoomPermissions?

    /// When set, the mention pill matching this user ID is rendered with a
    /// prominent highlight style to indicate the message mentions the user.
    var highlightedUserId: String?

    /// Keywords to highlight with a background color in the message body.
    var highlightKeywords: [String] = []

    private var foregroundColor: NSColor {
        isOutgoing ? .white : .labelColor
    }

    private var linkColor: NSColor {
        isOutgoing ? NSColor.white.withAlphaComponent(0.9) : .controlAccentColor
    }

    private var pillStyle: MentionPillStyle {
        isOutgoing ? .messageWhiteText : .messageDefault
    }

    /// Applies the bubble color, link color, and pill substitutions to a parsed
    /// attributed string using the current message styling.
    private func resolved(for source: NSAttributedString) -> NSAttributedString {
        Self.applyColorOverrides(
            source,
            foreground: foregroundColor,
            linkColor: linkColor,
            pillStyle: pillStyle,
            highlightedUserId: highlightedUserId,
            highlightKeywords: highlightKeywords
        )
    }

    // MARK: - Coordinator

    /// Caches the last resolved `NSAttributedString` so that `updateNSView`
    /// can skip the expensive `applyColorOverrides()` conversion when the
    /// inputs have not changed. Without this, every SwiftUI layout pass
    /// re-runs attribute enumeration on the main thread, which beach-balls
    /// when many messages are visible.
    final class Coordinator {
        var lastAttributedString: NSAttributedString?
        var lastIsOutgoing: Bool?
        var lastHighlightedUserId: String?
        var lastHighlightKeywords: [String] = []
        var cachedResolved: NSAttributedString?

        /// Cached result from `sizeThatFits` to avoid redundant layout
        /// passes when SwiftUI re-measures with the same proposal and text.
        var cachedSizeProposedWidth: CGFloat?
        var cachedSizeResult: CGSize?
        var cachedSizeTextLength: Int?
        var cachedSizeTextHash: Int?
        /// The ``sizeCacheGeneration`` the cached size was measured under. A
        /// width change bumps the generation to invalidate every cell's cache.
        var cachedSizeGeneration: Int = -1

        /// Offscreen TextKit 2 stack used exclusively for measurement in
        /// `sizeThatFits`. Measuring on a separate stack avoids mutating the
        /// display text view's `NSTextLayoutManager`, which would tear down
        /// and recreate `NSTextAttachmentViewProvider` views on every
        /// layout pass.
        let measureContentStorage = NSTextContentStorage()
        let measureLayoutManager = NSTextLayoutManager()
        let measureContainer: NSTextContainer = {
            let c = NSTextContainer(
                size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                             height: CGFloat.greatestFiniteMagnitude)
            )
            c.lineFragmentPadding = 0
            return c
        }()

        lazy var measureStackReady: Bool = {
            measureContentStorage.addTextLayoutManager(measureLayoutManager)
            measureLayoutManager.textContainer = measureContainer
            return true
        }()
    }

    /// Bumped whenever the timeline re-lays-out at a new width. Recycled cells
    /// keep their `Coordinator` (and its size cache) across a width change; a
    /// cell measured narrow mid-drag would otherwise return that stale, narrower
    /// width from `sizeThatFits`, so its bubble hugs the narrow width and wraps
    /// an extra line that clips. Invalidating the caches forces a fresh measure
    /// at the settled width. See ``invalidateSizeCaches()``.
    @MainActor static var sizeCacheGeneration: Int = 0

    /// Invalidates every cell's `sizeThatFits` cache (see ``sizeCacheGeneration``).
    @MainActor static func invalidateSizeCaches() { sizeCacheGeneration &+= 1 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MessageTextContent {
        // Default NSTextView init creates a TextKit 2 stack (NSTextLayoutManager),
        // enabling NSTextAttachmentViewProvider for live SwiftUI pill rendering.
        // The frame height is a placeholder — SwiftUI sizes the view via
        // `sizeThatFits`. A non-finite height is invalid view geometry.
        let view = MessageTextContent(
            frame: NSRect(x: 0, y: 0, width: 200, height: 10_000)
        )
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineFragmentPadding = 0
        view.clipsToBounds = false
        // Prevent NSTextView from flattening subviews into its own layer.
        // NSHostingView (used by NSTextAttachmentViewProvider for pills and
        // quote icons) manages its own backing layer. When the text view is
        // embedded in SwiftUI's layer-backed hierarchy,
        // canDrawSubviewsIntoLayer can default to true, which causes the
        // text view's drawing pass to overwrite the hosting views' layer
        // content — attachment views render briefly then go blank.
        view.canDrawSubviewsIntoLayer = false
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isAutomaticLinkDetectionEnabled = false
        view.setContentHuggingPriority(.required, for: .vertical)
        view.onUserTap = onUserTap
        view.onRoomTap = onRoomTap
        view.contextMessage = contextMessage
        view.onMessageContextAction = onMessageContextAction
        view.onPresentReactionPicker = onPresentReactionPicker
        view.permissions = permissions

        // Populate text immediately so sizeThatFits (which SwiftUI may
        // call before updateNSView) has content to measure. Without this,
        // the text storage is empty and sizeThatFits returns .zero,
        // causing the hosting controller to compute incorrect row heights.
        let coordinator = context.coordinator
        let resolved = resolved(for: attributedString)
        coordinator.lastAttributedString = attributedString
        coordinator.lastIsOutgoing = isOutgoing
        coordinator.lastHighlightedUserId = highlightedUserId
        coordinator.lastHighlightKeywords = highlightKeywords
        coordinator.cachedResolved = resolved
        view.linkTextAttributes = [.foregroundColor: linkColor]
        view.textStorage?.setAttributedString(resolved)

        return view
    }

    func updateNSView(_ view: MessageTextContent, context: Context) {
        view.resetHoverState()
        view.onUserTap = onUserTap
        view.onRoomTap = onRoomTap
        view.contextMessage = contextMessage
        view.onMessageContextAction = onMessageContextAction
        view.onPresentReactionPicker = onPresentReactionPicker
        view.permissions = permissions

        let coordinator = context.coordinator

        // Check whether the inputs that affect the resolved string have changed.
        let inputsChanged: Bool = {
            if coordinator.cachedResolved == nil { return true }
            if coordinator.lastIsOutgoing != isOutgoing { return true }
            if coordinator.lastHighlightedUserId != highlightedUserId { return true }
            if coordinator.lastHighlightKeywords != highlightKeywords { return true }
            return attributedString !== coordinator.lastAttributedString
        }()

        if inputsChanged {
            let resolved = resolved(for: attributedString)
            coordinator.lastAttributedString = attributedString
            coordinator.lastIsOutgoing = isOutgoing
            coordinator.lastHighlightedUserId = highlightedUserId
            coordinator.lastHighlightKeywords = highlightKeywords
            coordinator.cachedResolved = resolved

            view.linkTextAttributes = [.foregroundColor: linkColor]
            view.textStorage?.setAttributedString(resolved)

            // Invalidate the size cache — the text content changed.
            coordinator.cachedSizeResult = nil
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: MessageTextContent, context: Context
    ) -> CGSize? {
        guard let displayStorage = nsView.textStorage,
              displayStorage.length > 0
        else { return .zero }

        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let coordinator = context.coordinator
        let textHash = displayStorage.string.hashValue
        if let cached = coordinator.cachedSizeResult,
           coordinator.cachedSizeGeneration == Self.sizeCacheGeneration,
           coordinator.cachedSizeTextLength == displayStorage.length,
           coordinator.cachedSizeTextHash == textHash,
           coordinator.cachedSizeProposedWidth == proposedWidth {
            return cached
        }

        // Measure on a separate, offscreen TextKit 2 stack so the display
        // text view's NSTextLayoutManager is never mutated. This preserves
        // any NSTextAttachmentViewProvider views the display layout created
        // during rendering — mutating the display layout (as the old code
        // did) would tear those views down on every measurement pass.
        _ = coordinator.measureStackReady
        // swiftlint:disable:next identifier_name
        let ms = coordinator.measureContentStorage
        ms.textStorage?.setAttributedString(displayStorage)
        // swiftlint:disable:next identifier_name
        let tlm = coordinator.measureLayoutManager
        let container = coordinator.measureContainer

        // Natural layout (unconstrained) to find the intrinsic text width.
        container.size = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tlm.ensureLayout(for: tlm.documentRange)
        var naturalWidth: CGFloat = 0
        let docStart = tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for lineFragment in fragment.textLineFragments {
                var lineWidth = fragment.layoutFragmentFrame.origin.x
                    + lineFragment.typographicBounds.maxX
                if let fragStart = fragment.textElement?.elementRange?.location {
                    let fragOffset = ms.offset(from: docStart, to: fragStart)
                    let charIndex = fragOffset + lineFragment.characterRange.location
                    if charIndex < displayStorage.length,
                       // swiftlint:disable:next identifier_name
                       let ps = displayStorage.attribute(
                            .paragraphStyle, at: charIndex, effectiveRange: nil
                       ) as? NSParagraphStyle,
                       ps.tailIndent < 0 {
                        lineWidth -= ps.tailIndent
                    }
                }
                naturalWidth = max(naturalWidth, lineWidth)
            }
            return true
        }
        let naturalHeight = tlm.usageBoundsForTextContainer.height
        let tightWidth = ceil(naturalWidth)

        let result: CGSize

        // swiftlint:disable:next identifier_name
        if let pw = proposedWidth, pw > 0 {
            if tightWidth > pw {
                let wrapWidth = max(1, pw.rounded(.down))
                container.size = NSSize(width: wrapWidth, height: CGFloat.greatestFiniteMagnitude)
                tlm.ensureLayout(for: tlm.documentRange)
                let constrainedHeight = tlm.usageBoundsForTextContainer.height
                result = CGSize(width: wrapWidth, height: ceil(constrainedHeight))
            } else {
                result = CGSize(width: tightWidth, height: ceil(naturalHeight))
            }
        } else {
            let cappedWidth = min(tightWidth, 476) // 500 maxBubbleWidth - 24 bubblePadding
            if cappedWidth < tightWidth {
                container.size = NSSize(width: cappedWidth, height: CGFloat.greatestFiniteMagnitude)
                tlm.ensureLayout(for: tlm.documentRange)
                let h = tlm.usageBoundsForTextContainer.height
                result = CGSize(width: cappedWidth, height: ceil(h))
            } else {
                result = CGSize(width: tightWidth, height: ceil(naturalHeight))
            }
        }

        coordinator.cachedSizeProposedWidth = proposedWidth
        coordinator.cachedSizeResult = result
        coordinator.cachedSizeTextLength = displayStorage.length
        coordinator.cachedSizeTextHash = textHash
        coordinator.cachedSizeGeneration = Self.sizeCacheGeneration

        return result
    }

}

// MARK: - MessageTextContent (NSTextView subclass)

/// A read-only `NSTextView` subclass for rendering rich message text, defined
/// alongside its ``MessageTextView`` representable wrapper.
///
/// Provides native link hover behaviour (pointing-hand cursor and underline on
/// hover) and text selection. Designed to be extended for Matrix-specific
/// features such as mention pills and `matrix.to` links.
final class MessageTextContent: NSTextView {

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
        if let textContainer, newSize.width > 0 {
            textContainer.size = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
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
        guard let textLayoutManager,
              let textContentStorage = textLayoutManager.textContentManager as? NSTextContentStorage,
              let textStorage else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)

        guard let fragment = textLayoutManager.textLayoutFragment(for: local) else { return nil }
        let fragmentLocal = NSPoint(
            x: local.x - fragment.layoutFragmentFrame.origin.x,
            y: local.y - fragment.layoutFragmentFrame.origin.y
        )

        guard let lineFragment = fragment.textLineFragment(
            forVerticalOffset: fragmentLocal.y, requiresExactMatch: false
        ) else { return nil }

        let lineLocal = NSPoint(
            x: fragmentLocal.x - lineFragment.typographicBounds.origin.x,
            y: fragmentLocal.y - lineFragment.typographicBounds.origin.y
        )
        let localCharIndex = lineFragment.characterIndex(for: lineLocal)

        guard let fragStart = fragment.textElement?.elementRange?.location else { return nil }
        let fragOffset = textContentStorage.offset(
            from: textLayoutManager.documentRange.location, to: fragStart
        )
        guard fragOffset >= 0, localCharIndex >= 0 else { return nil }
        let charIndex = fragOffset + localCharIndex
        guard charIndex >= 0, charIndex < textStorage.length else { return nil }

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

// MARK: - Previews

private struct BubblePreview: View {
    let text: String
    let isOutgoing: Bool

    var body: some View {
        MessageTextView(
            attributedString: NSAttributedString(matrixMarkdown: text),
            isOutgoing: isOutgoing
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2))
        .clipShape(.rect(cornerRadius: 17))
    }
}

private struct HTMLBubblePreview: View {
    let html: String
    let isOutgoing: Bool

    var body: some View {
        Group {
            if let resolved = NSAttributedString(matrixHTML: html) {
                MessageTextView(attributedString: resolved, isOutgoing: isOutgoing)
            } else {
                Text("Parse error")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2))
        .clipShape(.rect(cornerRadius: 17))
    }
}

#Preview("Plain Text") {
    VStack(alignment: .leading, spacing: 12) {
        BubblePreview(text: "Yeah", isOutgoing: false)
        BubblePreview(text: "Oh, per room..", isOutgoing: true)
        BubblePreview(
            text: "I think it's the same across the board. Some rooms just limit posts and block images",
            isOutgoing: false
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Markdown Formatting") {
    VStack(alignment: .leading, spacing: 12) {
        BubblePreview(text: "This is **bold** text", isOutgoing: false)
        BubblePreview(text: "This is *italic* text", isOutgoing: false)
        BubblePreview(text: "This has `inline code` in it", isOutgoing: false)
        BubblePreview(text: "This is ~~strikethrough~~ text", isOutgoing: false)
        BubblePreview(
            text: "**Bold**, *italic*, `code`, and ~~struck~~ all at once",
            isOutgoing: false
        )
        BubblePreview(
            text: "Outgoing with **bold** and a link https://example.com",
            isOutgoing: true
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Mention Pills") {
    VStack(alignment: .leading, spacing: 12) {
        HTMLBubblePreview(
            html: """
            <p>Hey <a href="https://matrix.to/#/@alice:matrix.org">Alice</a>, \
            did you see the update?</p>
            """,
            isOutgoing: false
        )
        HTMLBubblePreview(
            html: """
            <p>Thanks <a href="https://matrix.to/#/@bob:example.com">Bob Smith</a>! \
            Let me check with <a href="https://matrix.to/#/@charlie:matrix.org">Charlie</a> too.</p>
            """,
            isOutgoing: true
        )
        BubblePreview(
            text: "Ping [@dave:matrix.org](https://matrix.to/#/@dave:matrix.org)",
            isOutgoing: false
        )
    }
    .padding()
    .frame(width: 500)
}
