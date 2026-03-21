import QuickLook
import RelayCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media Auto-Reveal Environment

private struct MediaAutoRevealKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Controls whether media attachments in messages are shown immediately or hidden behind a tap-to-reveal overlay.
    var mediaAutoReveal: Bool {
        get { self[MediaAutoRevealKey.self] }
        set { self[MediaAutoRevealKey.self] = newValue }
    }
}

/// Renders a single chat bubble for a timeline message, with support for text, images,
/// emotes, special types (encrypted, redacted, etc.), reactions, and inline reply context.
struct MessageView: View {
    /// The timeline message to render.
    let message: TimelineMessage

    /// Whether this message is the last in a consecutive group from the same sender.
    /// Controls avatar visibility.
    var isLastInGroup: Bool = true

    /// Whether to display the sender's name above the bubble (for the first message in a group).
    var showSenderName: Bool = false

    /// Called when a reaction emoji is tapped to toggle it on the message.
    var onToggleReaction: ((String) -> Void)?

    /// Called when the inline reply preview is tapped, with the event ID to scroll to.
    var onTapReply: ((String) -> Void)?

    /// Called when the user double-taps the sender's avatar to open their profile.
    var onAvatarDoubleTap: (() -> Void)?

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 6) {
                if message.isOutgoing {
                    Spacer(minLength: 60)
                }

                if !message.isOutgoing {
                    if isLastInGroup {
                        AvatarView(
                            name: message.displayName,
                            mxcURL: message.senderAvatarURL,
                            size: 28
                        )
                        .onTapGesture(count: 2) { onAvatarDoubleTap?() }
                    } else {
                        Spacer()
                            .frame(width: 28)
                    }
                }

                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 1) {
                    if showSenderName && !message.isOutgoing {
                        Text(message.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .padding(.bottom, 2)
                    }

                    if message.kind == .image, message.mediaInfo != nil {
                        imageContent
                    } else if message.kind == .emote {
                        emoteContent
                    } else if message.isSpecialType {
                        specialContent
                    } else {
                        textContent
                    }
                }

                if !message.isOutgoing {
                    Spacer(minLength: 60)
                }
            }

            if !message.reactions.isEmpty {
                ReactionsView(
                    reactions: message.reactions,
                    onToggle: { key in onToggleReaction?(key) }
                )
                .padding(.leading, message.isOutgoing ? 0 : 34)
            }
        }
        .padding(.vertical, message.isHighlighted ? 4 : 0)
        .padding(.horizontal, message.isHighlighted ? 6 : 0)
        .background {
            if message.isHighlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(alignment: .trailing) {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 8, topTrailingRadius: 8
                        )
                        .fill(Color.orange)
                        .frame(width: 3)
                    }
            }
        }
    }

    // MARK: - Inline Reply

    @ViewBuilder
    private func inlineReply(_ reply: TimelineMessage.ReplyDetail, outgoing: Bool) -> some View {
        Button {
            onTapReply?(reply.eventID)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(outgoing ? Color.white.opacity(0.5) : Color.accentColor)
                    .frame(width: 3, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.displayName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(outgoing ? .white.opacity(0.8) : Color.accentColor)
                        .lineLimit(1)
                    Text(reply.body)
                        .font(.caption)
                        .foregroundStyle(outgoing ? .white.opacity(0.6) : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Image Content

    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reply = message.replyDetail {
                inlineReply(reply, outgoing: message.isOutgoing)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .background(bubbleColor)
            }
            ImageMessageView(message: message)
        }
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // MARK: - Text Content (with markdown + links)

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.replyDetail {
                inlineReply(reply, outgoing: message.isOutgoing)
            }
            Text(markdownBody)
                .tint(message.isOutgoing ? .white.opacity(0.9) : .accentColor)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(bubbleColor)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .foregroundStyle(message.isOutgoing ? .white : .primary)
    }

    // MARK: - Emote Content

    private var emoteContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.replyDetail {
                inlineReply(reply, outgoing: false)
            }
            Text("*\(message.displayName)* \(markdownBody)")
                .tint(.accentColor)
                .italic()
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.purple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .foregroundStyle(.primary)
    }

    // MARK: - Special Content (media, redacted, encrypted, etc.)

    private var specialContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.replyDetail {
                inlineReply(reply, outgoing: message.isOutgoing)
            }
            Label {
                Text(message.body)
                    .font(.callout)
            } icon: {
                Image(systemName: iconForKind)
                    .font(.callout)
            }
            .foregroundStyle(foregroundForKind.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(backgroundForKind)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var iconForKind: String {
        switch message.kind {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .file: "doc"
        case .location: "location"
        case .sticker: "face.smiling"
        case .poll: "chart.bar"
        case .redacted: "trash"
        case .encrypted: "lock.fill"
        case .other: "questionmark.circle"
        default: "bubble.left"
        }
    }

    private var foregroundForKind: Color {
        switch message.kind {
        case .encrypted: .orange
        default: .primary
        }
    }

    @ViewBuilder
    private var backgroundForKind: some View {
        switch message.kind {
        case .redacted:
            Color(.systemGray).opacity(0.1)
        case .encrypted:
            Color.orange.opacity(0.1)
        default:
            Color(.systemGray).opacity(0.15)
        }
    }

    // MARK: - Markdown Parsing

    private var markdownBody: AttributedString {
        let raw = message.body
        if let md = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return md
        }
        return AttributedString(raw)
    }

    // MARK: - Bubble Color

    private var bubbleColor: Color {
        message.isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2)
    }
}

// MARK: - Image Message View

private struct ImageMessageView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.mediaAutoReveal) private var autoReveal
    let message: TimelineMessage

    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var isHovering = false
    @State private var quickLookURL: URL?
    @State private var isLoadingFullImage = false
    @State private var errorMessage: String?
    @State private var isRevealed = false

    private var mediaInfo: TimelineMessage.MediaInfo {
        message.mediaInfo!
    }

    private var displaySize: CGSize {
        let maxWidth: CGFloat = 280
        let maxHeight: CGFloat = 320
        if let w = mediaInfo.width, let h = mediaInfo.height, w > 0, h > 0 {
            let aspect = CGFloat(w) / CGFloat(h)
            let width = min(CGFloat(w), maxWidth)
            let height = width / aspect
            if height > maxHeight {
                return CGSize(width: maxHeight * aspect, height: maxHeight)
            }
            return CGSize(width: width, height: height)
        }
        return CGSize(width: maxWidth, height: 200)
    }

    private var shouldShow: Bool { autoReveal || isRevealed }

    var body: some View {
        ZStack {
            if shouldShow {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray).opacity(0.15))
                        .frame(width: displaySize.width, height: displaySize.height)
                        .overlay {
                            if isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            } else {
                Rectangle()
                    .fill(Color(.systemGray).opacity(0.15))
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Media Hidden")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onTapGesture { isRevealed = true }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if shouldShow, image != nil {
                downloadButton
                    .padding(8)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if shouldShow, let caption = mediaInfo.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(8)
            }
        }
        .onTapGesture(count: 2) {
            if shouldShow {
                Task { await openQuickLook() }
            }
        }
        .overlay {
            if isLoadingFullImage {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay { ProgressView() }
            }
        }
        .quickLookPreview($quickLookURL)
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .task(id: shouldShow ? mediaInfo.mxcURL : nil) {
            guard shouldShow else { return }
            isLoading = true
            if let data = await matrixService.mediaThumbnail(
                mxcURL: mediaInfo.mxcURL,
                width: UInt64(displaySize.width * 2),
                height: UInt64(displaySize.height * 2)
            ) {
                image = NSImage(data: data)
            }
            isLoading = false
        }
    }

    private var downloadButton: some View {
        Button {
            Task { await saveImage() }
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.5))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
    }

    private func openQuickLook() async {
        guard !isLoadingFullImage else { return }
        isLoadingFullImage = true
        defer { isLoadingFullImage = false }

        guard let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) else { return }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(mediaInfo.filename)
        do {
            try data.write(to: url)
            quickLookURL = url
        } catch {
            errorMessage = "Could not preview image: \(error.localizedDescription)"
        }
    }

    private func saveImage() async {
        guard let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = mediaInfo.filename
        panel.allowedContentTypes = [.image]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        try? data.write(to: url)
    }
}

// MARK: - Message Swipe Actions

/// Wraps a ``MessageView`` with a two-finger horizontal swipe gesture that reveals reply
/// and react action buttons behind the message.
///
/// Uses an AppKit `NSView` overlay to intercept horizontal `scrollWheel` events from the
/// trackpad before the parent `ScrollView` consumes them.
///
/// - **Partial swipe** (lift fingers before the trigger threshold): The message stays offset,
///   revealing a reply button and a react button side by side. The user can tap either one.
/// - **Full swipe** (past the trigger threshold): Fires the reply action immediately
///   and snaps the message back.
/// - Tapping anywhere on the message while buttons are revealed dismisses them.
struct MessageSwipeActions<Content: View>: View {
    /// Unique identifier for this message, used to coordinate revealed state with the parent.
    let messageId: String

    /// Binding to the parent's tracked revealed-message ID. When this matches `messageId`,
    /// the action buttons are shown. Setting it to `nil` from the parent dismisses any
    /// revealed actions (e.g. tapping outside).
    @Binding var revealedMessageId: String?

    /// The message content to display (typically a ``MessageView``).
    @ViewBuilder let content: () -> Content

    /// Called when the user triggers a reply (full swipe or tapping the reply button).
    var onReply: (() -> Void)?

    /// Called when the user taps the react button.
    var onAddReaction: (() -> Void)?

    // MARK: - Gesture state

    /// The resting offset when buttons are revealed (button area + trailing gap).
    private let revealedWidth: CGFloat = 88

    /// The drag distance required to trigger the reply action on a full swipe.
    private let triggerThreshold: CGFloat = 140

    /// Current horizontal translation of the message.
    @State private var offsetX: CGFloat = 0

    /// Tracks whether the full-swipe reply was already fired for the current gesture.
    @State private var didTriggerReply = false

    /// Whether a horizontal scroll gesture is actively being tracked.
    @State private var isTracking = false

    /// Whether this message's actions are currently revealed.
    private var isRevealed: Bool { revealedMessageId == messageId }

    var body: some View {
        ZStack(alignment: .leading) {
            // Action buttons revealed behind the message
            actionButtons
                .opacity(actionButtonsOpacity)

            // The message content, offset by the swipe
            content()
                .offset(x: offsetX)
                .overlay {
                    HorizontalScrollInterceptor(
                        onScrollDelta: handleScrollDelta,
                        onScrollEnd: handleScrollEnd
                    )
                }
        }
        .clipped()
        .onChange(of: revealedMessageId) { _, newValue in
            // Another message was swiped, or the parent dismissed us — snap back.
            if newValue != messageId && offsetX != 0 {
                withAnimation(.snappy(duration: 0.25)) {
                    offsetX = 0
                }
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 2) {
            Button {
                dismiss()
                onReply?()
            } label: {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
                onAddReaction?()
            } label: {
                Image(systemName: "face.smiling.inverse")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
    }

    private var actionButtonsOpacity: Double {
        let progress = min(max(offsetX / revealedWidth, 0), 1)
        return Double(progress)
    }

    // MARK: - Scroll Event Handling

    private func handleScrollDelta(_ deltaX: CGFloat) {
        isTracking = true

        let base = isRevealed ? revealedWidth : 0
        let proposed = base + deltaX
        offsetX = max(0, proposed)

        if offsetX >= triggerThreshold && !didTriggerReply {
            didTriggerReply = true
        }
    }

    private func handleScrollEnd() {
        isTracking = false

        if didTriggerReply {
            dismiss()
            didTriggerReply = false
            onReply?()
        } else if offsetX > revealedWidth * 0.5 {
            withAnimation(.snappy(duration: 0.25)) {
                offsetX = revealedWidth
                revealedMessageId = messageId
            }
        } else {
            dismiss()
        }
        didTriggerReply = false
    }

    private func dismiss() {
        withAnimation(.snappy(duration: 0.25)) {
            offsetX = 0
            revealedMessageId = nil
        }
    }
}

// MARK: - Horizontal Scroll Interceptor (AppKit)

/// An `NSViewRepresentable` that places an invisible `NSView` over the message content to
/// intercept horizontal `scrollWheel` events from two-finger trackpad swipes.
///
/// When the initial scroll direction is predominantly horizontal, this view captures the
/// gesture and reports deltas. Vertical-dominant scrolls are passed through to the parent
/// `ScrollView` for normal timeline scrolling.
private struct HorizontalScrollInterceptor: NSViewRepresentable {
    /// Called with the accumulated horizontal delta (in points) during an active swipe.
    let onScrollDelta: (CGFloat) -> Void

    /// Called when the scroll gesture ends (fingers lifted and momentum finished).
    let onScrollEnd: () -> Void

    func makeNSView(context: Context) -> ScrollInterceptorView {
        let view = ScrollInterceptorView()
        view.onScrollDelta = onScrollDelta
        view.onScrollEnd = onScrollEnd
        return view
    }

    func updateNSView(_ nsView: ScrollInterceptorView, context: Context) {
        nsView.onScrollDelta = onScrollDelta
        nsView.onScrollEnd = onScrollEnd
    }
}

/// The AppKit view that performs the actual scroll-wheel interception.
final class ScrollInterceptorView: NSView {
    var onScrollDelta: ((CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?

    /// Whether we have decided this gesture is horizontal (captured) or vertical (pass-through).
    private var gestureAxis: GestureAxis = .undecided

    /// Accumulated horizontal scroll since the gesture began.
    private var accumulatedDeltaX: CGFloat = 0

    /// Minimum total scroll distance before we commit to an axis.
    private let axisLockThreshold: CGFloat = 4

    private enum GestureAxis {
        case undecided, horizontal, vertical
    }

    override var isFlipped: Bool { true }

    // Only accept scroll-wheel hit tests. For all other events (mouse clicks, etc.),
    // return nil so they pass through to the SwiftUI buttons underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // During a scroll-wheel gesture the system has already resolved the hit target,
        // so hitTest is only called for new event sequences (clicks, drags, etc.).
        // Returning nil lets those fall through to the action buttons below.
        return nil
    }

    // Scroll-wheel events are delivered based on the cursor location, not hitTest.
    // We receive them via the responder chain by installing a local event monitor.
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let _ = self.window else { return event }
                // Check if the cursor is within this view's bounds.
                let locationInWindow = event.locationInWindow
                let locationInView = self.convert(locationInWindow, from: nil)
                guard self.bounds.contains(locationInView) else { return event }
                self.handleScroll(with: event)
                // If we captured this as a horizontal gesture, consume the event.
                if self.gestureAxis == .horizontal {
                    return nil
                }
                return event
            }
        } else if window == nil, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    override func removeFromSuperview() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        super.removeFromSuperview()
    }

    private func handleScroll(with event: NSEvent) {
        switch event.phase {
        case .began:
            gestureAxis = .undecided
            accumulatedDeltaX = 0

        case .changed:
            switch gestureAxis {
            case .undecided:
                let absX = abs(event.scrollingDeltaX)
                let absY = abs(event.scrollingDeltaY)
                let total = absX + absY

                if total >= axisLockThreshold {
                    if absX > absY {
                        let delta = event.scrollingDeltaX
                        if delta > 0 || accumulatedDeltaX > 0 {
                            gestureAxis = .horizontal
                            accumulatedDeltaX += delta
                            accumulatedDeltaX = max(0, accumulatedDeltaX)
                            onScrollDelta?(accumulatedDeltaX)
                        } else {
                            // Leftward initial direction: pass through for scrolling
                            gestureAxis = .vertical
                        }
                    } else {
                        gestureAxis = .vertical
                    }
                }

            case .horizontal:
                let delta = event.scrollingDeltaX
                accumulatedDeltaX += delta
                accumulatedDeltaX = max(0, accumulatedDeltaX)
                onScrollDelta?(accumulatedDeltaX)

            case .vertical:
                break // Event monitor returns the event, so ScrollView gets it
            }

        case .ended, .cancelled:
            if gestureAxis == .horizontal {
                onScrollEnd?()
            }
            gestureAxis = .undecided
            accumulatedDeltaX = 0

        default:
            break // Momentum events pass through via the monitor returning the event
        }
    }
}

// MARK: - Reactions View

private struct ReactionsView: View {
    let reactions: [TimelineMessage.ReactionGroup]
    let onToggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    onToggle(reaction.key)
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.key)
                            .font(.body)
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(reaction.highlightedByCurrentUser ? .white : .secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        reaction.highlightedByCurrentUser
                            ? Color.accentColor.opacity(0.25)
                            : Color(.systemGray).opacity(0.12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                reaction.highlightedByCurrentUser
                                    ? Color.accentColor.opacity(0.5)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width }
                + CGFloat(max(0, row.count - 1)) * spacing
            height += rowHeight + (i > 0 ? spacing : 0)
            maxRowWidth = max(maxRowWidth, rowWidth)
        }
        return CGSize(width: maxRowWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for (i, row) in rows.enumerated() {
            if i > 0 { y += spacing }
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
                x += size.width + spacing
            }
            y += rowHeight
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width + spacing > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

// MARK: - Previews

#Preview("Conversation") {
    VStack(spacing: 2) {
        MessageView(
            message: TimelineMessage(
                id: "1",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice",
                body: "Hey, check out **this link**: https://matrix.org",
                timestamp: .now.addingTimeInterval(-120),
                isOutgoing: false
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "1b",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice",
                body: "It supports *italic*, **bold**, and `code`!",
                timestamp: .now.addingTimeInterval(-110),
                isOutgoing: false,
                reactions: [.init(key: "❤️", count: 1, senderIDs: ["@me:matrix.org"], highlightedByCurrentUser: true)]
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "2",
                senderID: "@me:matrix.org",
                body: "Nice — I'll take a look.",
                timestamp: .now.addingTimeInterval(-60),
                isOutgoing: true,
                reactions: [
                    .init(key: "👍", count: 2, senderIDs: ["@alice:matrix.org", "@bob:matrix.org"], highlightedByCurrentUser: false),
                    .init(key: "❤️", count: 1, senderIDs: ["@alice:matrix.org"], highlightedByCurrentUser: false),
                    .init(key: "🎉", count: 1, senderIDs: ["@me:matrix.org"], highlightedByCurrentUser: true),
                ],
                replyDetail: .init(eventID: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice", body: "Hey, check out **this link**: https://matrix.org")
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "3",
                senderID: "@bob:matrix.org",
                senderDisplayName: "Bob",
                body: "Hey @me:matrix.org, can you review the PR when you get a chance?",
                timestamp: .now.addingTimeInterval(-30),
                isOutgoing: false,
                isHighlighted: true,
                replyDetail: .init(eventID: "2", senderID: "@me:matrix.org", senderDisplayName: "Me", body: "Nice — I'll take a look.")
            ),
            showSenderName: true
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Image Message") {
    VStack(spacing: 6) {
        MessageView(
            message: TimelineMessage(
                id: "img1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "Image", timestamp: .now, isOutgoing: false, kind: .image,
                mediaInfo: .init(
                    mxcURL: "mxc://matrix.org/example",
                    filename: "photo.jpg",
                    mimetype: "image/jpeg",
                    width: 800, height: 600
                )
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "img2", senderID: "@me:matrix.org",
                body: "Check this out", timestamp: .now, isOutgoing: true, kind: .image,
                mediaInfo: .init(
                    mxcURL: "mxc://matrix.org/example2",
                    filename: "screenshot.png",
                    mimetype: "image/png",
                    width: 400, height: 700,
                    caption: "Check this out"
                )
            )
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Special Types") {
    VStack(spacing: 6) {
        MessageView(
            message: TimelineMessage(
                id: "d1", senderID: "@mod:matrix.org", senderDisplayName: "Moderator",
                body: "This message was deleted", timestamp: .now, isOutgoing: false, kind: .redacted
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "e1", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
                body: "Waiting for encryption key", timestamp: .now, isOutgoing: false, kind: .encrypted
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "v1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "Video", timestamp: .now, isOutgoing: false, kind: .video
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "f1", senderID: "@me:matrix.org",
                body: "File", timestamp: .now, isOutgoing: true, kind: .file
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "em1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "waves hello", timestamp: .now, isOutgoing: false, kind: .emote
            ),
            showSenderName: true
        )
    }
    .padding()
    .frame(width: 500)
}
