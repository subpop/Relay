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

import Intents
import Logging
import MatrixKit
import os
import RelayShared
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "Relay", category: "DeepLink")

/// The main entry point for the Relay macOS application.
///
/// ``RelayApp`` creates the ``RelayClient``, injects it into the SwiftUI environment,
/// manages the dock badge for unread counts, and posts local notifications for
/// incoming verification requests and room messages.
@main
struct RelayApp: App {
    /// `true` when Xcode is running the process solely to render SwiftUI
    /// previews. Checked once at launch so that heavy services (Matrix SDK,
    /// keychain, network monitor, etc.) are never created in preview mode.
    private static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    @State private var client = RelayClient()
    @State private var callManager = CallManager()
    @State private var notificationDelegate = NotificationDelegate()
    @State private var appActions = AppActions()
    @State private var composeDraftStore = ComposeDraftStore()
    @State private var showClearCacheConfirmation = false

    /// Installs the swift-log → Activity Log bridge exactly once per
    /// process (previews may construct the app repeatedly, and a second
    /// bootstrap would trap). MatrixKit records flow into the Activity
    /// Log window, trace included; the console prints error-and-above
    /// only. Installed in `init`, before any MatrixKit logger exists.
    private static let installLoggingBridge: Void = {
        LoggingSystem.bootstrap { label in
            var console = StreamLogHandler.standardError(label: label)
            console.logLevel = .error
            return MultiplexLogHandler([
                MatrixKitLogBridge(label: label),
                console,
            ])
        }
    }()

    init() {
        _ = Self.installLoggingBridge
    }

    /// GIF search backend (GIPHY). Empty API keys fail gracefully in the picker.
    private var gifSearchService: any GIFSearchServiceProtocol {
        GiphyService(apiKey: Secrets.giphyAPIKey ?? "", identityStore: .shared)
    }

    @Environment(\.openWindow) private var openWindow

    @AppStorage("selectedRoomId") private var selectedRoomId: String?
    @AppStorage("appearance.mode") private var appearanceMode: AppAppearance = .system

    var body: some Scene {
        WindowGroup(id: "main") {
            contentView
        }
        .defaultSize(width: 880, height: 560)
        .commands {
            FileMenuCommands(appActions: appActions)
            EditLastMessageCommand(appActions: appActions)
            SearchCommand(appActions: appActions)
            QuickSwitchCommand(appActions: appActions)
            SidebarCommands()
            InspectorCommands()
            TextSizeCommands()
            CommandGroup(before: .appTermination) {
                Button("Clear Cache…") {
                    showClearCacheConfirmation = true
                }
            }
            CommandGroup(after: .windowArrangement) {
                Button("Relay") {
                    NSApp.activate()
                    if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                        window.deminiaturize(nil)
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "main")
                    }
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(client)
                .environment(\.errorReporter, client.errorReporter)
                .environment(\.gifSearchService, gifSearchService)
                .preferredColorScheme(appearanceMode.colorScheme)
        }

        Window("Activity Log", id: "activity-log") {
            ActivityLogView()
                .environment(client)
                .environment(\.activityLog, ActivityLog.shared)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .defaultSize(width: 900, height: 600)
        .keyboardShortcut("a", modifiers: [.option, .command])

        Window("Call", id: "call") {
            CallWindowView()
                .environment(\.callManager, callManager)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 360, height: 540)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(.suppressed)
    }

    /// The root content view, configured with real services at runtime or
    /// bare (using environment-key defaults) during Xcode previews.
    @ViewBuilder private var contentView: some View {
        if Self.isPreview {
            ContentView()
                .preferredColorScheme(appearanceMode.colorScheme)
        } else {
            ContentView()
                .environment(client)
                .environment(\.errorReporter, client.errorReporter)
                .environment(\.callManager, callManager)
                .environment(\.composeDraftStore, composeDraftStore)
                .environment(\.gifSearchService, gifSearchService)
                .environment(appActions)
                .onChange(of: dockBadgeCount) { _, newCount in
                    NSApp.dockTile.badgeLabel = newCount > 0 ? "\(newCount)" : nil
                }
                .onChange(of: client.pendingVerificationRequest?.id) { _, newValue in
                    if newValue != nil, let request = client.pendingVerificationRequest {
                        postVerificationNotification(request: request)
                    }
                }
                .onOpenURL { url in
                    if let uri = MatrixURI(url: url) {
                        logger.info("Received deep link: \(url.absoluteString)")
                        client.pendingDeepLink = uri
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    checkForPendingShare()
                }
                .onContinueUserActivity(NSStringFromClass(INSendMessageIntent.self)) { activity in
                    if let intent = activity.interaction?.intent as? INSendMessageIntent,
                       let roomId = intent.conversationIdentifier {
                        logger.info("Received share suggestion for room: \(roomId)")
                        selectedRoomId = roomId
                    }
                }
                .task {
                    await setupNotifications()
                }
                .task {
                    for await event in client.notificationEvents() {
                        handleNotificationEvent(event)
                    }
                }
                .alert("Clear Cache", isPresented: $showClearCacheConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear Cache", role: .destructive) {
                        Task { await client.clearLocalData() }
                    }
                } message: {
                    Text("This will delete all locally cached data and resync from the server. You will remain logged in.")
                }
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }

    // MARK: - Notifications

    private func setupNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        notificationDelegate.client = client
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])

        // Register the verification request notification category with an Accept action.
        let acceptAction = UNNotificationAction(
            identifier: NotificationDelegate.acceptActionIdentifier,
            title: "Accept",
            options: [.foreground]
        )
        let verificationCategory = UNNotificationCategory(
            identifier: NotificationDelegate.verificationCategoryIdentifier,
            actions: [acceptAction],
            intentIdentifiers: []
        )
        let roomMessageCategory = UNNotificationCategory(
            identifier: NotificationDelegate.roomMessageCategoryIdentifier,
            actions: [],
            intentIdentifiers: []
        )
        center.setNotificationCategories([verificationCategory, roomMessageCategory])
    }

    /// The total dock badge count, computed from every room's notification-worthy unread state.
    ///
    /// The count respects each room's cached notification mode:
    /// - All Messages: counts all unread messages
    /// - Mentions & Keywords Only: counts only unread mentions
    /// - Mute: counts nothing
    /// - Default (uncached): DMs count all notifications, groups count highlights only
    private var dockBadgeCount: Int {
        client.rooms.reduce(0) { total, room in
            switch client.notificationModeCache[room.roomId.value] {
            case .mute:
                return total
            case .mentionsAndKeywordsOnly:
                return total + client.displayHighlightCount(for: room)
            case .allMessages:
                return total + client.displayUnreadCount(for: room)
            case nil:
                return room.isDirect ? total + client.displayUnreadCount(for: room) : total + client.displayHighlightCount(for: room)
            }
        }
    }

    /// Checks the app group container for a pending share from the share extension.
    ///
    /// The extension writes the share ID to the ``PendingShareStore`` signal
    /// file and activates the app. This method reads that file, loads the corresponding pending share
    /// record, navigates to the target room, and stages the attachments in the
    /// compose bar for user review.
    private func checkForPendingShare() {
        guard let container = AppGroup.containerURL else { return }

        let signalURL = container.appending(path: PendingShareStore.signalFilename)
        guard let idString = try? String(contentsOf: signalURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let shareId = UUID(uuidString: idString) else {
            return
        }

        // Remove the signal file immediately to avoid re-processing.
        try? FileManager.default.removeItem(at: signalURL)

        let pendingShares = PendingShareStore.loadAll()
        guard let share = pendingShares.first(where: { $0.id == shareId }) else {
            logger.warning("Pending share not found: \(idString)")
            return
        }

        logger.info("Share handoff: \(share.filenames.count) file(s) for room \(share.roomId)")

        // Navigate to the target room.
        selectedRoomId = share.roomId

        // Resolve file URLs from the app group container and stage them.
        let fileURLs = share.filenames.compactMap { PendingShareStore.fileURL(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !fileURLs.isEmpty else {
            logger.warning("No valid files found for pending share \(idString)")
            PendingShareStore.remove(id: shareId)
            return
        }

        // Stage attachments in the compose bar for the target room.
        let draft = composeDraftStore.draft(for: share.roomId)
        draft.stageAttachments(fileURLs, errorReporter: ErrorReporter())

        // Remove the pending share record (files will be cleaned up after send
        // by TimelineViewModel.sendAttachment, which deletes the temp URL).
        PendingShareStore.remove(id: shareId)
    }

    private func postVerificationNotification(request: RelayClient.IncomingVerification) {
        let content = UNMutableNotificationContent()
        content.title = "Verification Request"
        content.body = "Another device (\(request.deviceId)) wants to verify this session."
        content.sound = .default
        content.categoryIdentifier = NotificationDelegate.verificationCategoryIdentifier
        content.userInfo = ["flowId": request.flowId]

        let notificationRequest = UNNotificationRequest(
            identifier: "verification-\(request.flowId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notificationRequest)
    }

    /// Post a local banner for an incoming room message.
    ///
    /// Direct chats show the room name; group rooms show "author in room".
    /// When the app is active with the room open, the banner is suppressed
    /// (`.passive`) but the sound still plays.
    private func handleNotificationEvent(_ event: RelayClient.RoomMessageNotification) {
        let content = UNMutableNotificationContent()
        content.title = event.isDirect ? event.roomName : "\(event.authorName ?? "Unknown sender") in \(event.roomName)"
        content.body = event.body
        content.sound = .default
        content.threadIdentifier = event.roomId
        content.userInfo = ["roomId": event.roomId]
        content.categoryIdentifier = NotificationDelegate.roomMessageCategoryIdentifier
        if NSApp.isActive && selectedRoomId == event.roomId {
            content.interruptionLevel = .passive
        }

        let notificationRequest = UNNotificationRequest(
            identifier: "message-\(event.eventId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notificationRequest)
    }
}

// MARK: - App Actions

/// Shared observable state that bridges menu commands with the main view hierarchy.
///
/// ``AppActions`` is created at the app level and injected into both the SwiftUI
/// environment (for views) and the ``FileMenuCommands`` struct. ``MainView``
/// observes these flags and presents the corresponding UI.
@Observable
final class AppActions {
    var showCreateRoom = false
    var showCreateSpace = false
    var showCreateDirectMessage = false
    var showJoinRoom = false
    var showRoomDirectory = false
    var focusSearch = false
    var showQuickSwitch = false
    /// The currently focused timeline's edit-last-message action, if any.
    ///
    /// Plain registry slot replacing the old focused-value publishing: the
    /// focused ``TimelineView`` installs a stable closure here and withdraws
    /// it on disappear, so the command graph never republishes per render
    /// (which tore down the open Window menu on Tahoe).
    var editLastMessageTarget: EditLastMessageTarget?
}

/// The focused timeline's edit-last-message action, published through
/// ``AppActions`` instead of the focus system.
struct EditLastMessageTarget {
    /// Identifies the registering timeline; used so a disappearing timeline
    /// only withdraws its own registration.
    let owner: AnyObject
    let perform: () -> Void
}

// MARK: - File Menu Commands

/// Replaces the default File menu items with room-related commands.
///
/// The standard "New Window" item is removed since Relay supports only a single window.
struct FileMenuCommands: Commands {
    let appActions: AppActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Create Room…") {
                appActions.showCreateRoom = true
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Create Space…") {
                appActions.showCreateSpace = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Create Direct Message…") {
                appActions.showCreateDirectMessage = true
            }
            .keyboardShortcut("n", modifiers: [.command, .control])

            Divider()

            Button("Join Room…") {
                appActions.showJoinRoom = true
            }
            .keyboardShortcut("j", modifiers: .command)

            Button("Room Directory") {
                appActions.showRoomDirectory = true
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Edit Last Message Command

/// Adds an "Edit Last Message" item (⌘E) to the Edit menu.
///
/// The command resolves its target through ``AppActions/editLastMessageTarget``,
/// published by the focused ``TimelineView``. When a timeline is focused and
/// contains at least one outgoing text message, pressing ⌘E starts editing
/// that message. Deliberately focus-free: publishing through the focus system
/// re-resolved the command graph on every render, which tore down the open
/// Window menu on Tahoe.
struct EditLastMessageCommand: Commands {
    let appActions: AppActions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Edit Last Message") {
                appActions.editLastMessageTarget?.perform()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(appActions.editLastMessageTarget == nil)
        }
    }
}

// MARK: - Search Command

/// Adds a "Search…" item (⌘G) to the Edit menu.
///
/// When pressed, the command sets ``AppActions/focusSearch`` to `true`.
/// ``MainView`` observes this flag and moves keyboard focus to the
/// toolbar search field.
struct SearchCommand: Commands {
    let appActions: AppActions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Search\u{2026}") {
                appActions.focusSearch = true
            }
            .keyboardShortcut("g", modifiers: .command)
        }
    }
}

// MARK: - Quick Switch Command

/// Adds a "Quick Switch…" item (⌘K) to the Edit menu.
///
/// When pressed, the command sets ``AppActions/showQuickSwitch`` to `true`.
/// ``MainView`` observes this flag and presents the quick room switch overlay.
struct QuickSwitchCommand: Commands {
    let appActions: AppActions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Quick Switch\u{2026}") {
                appActions.showQuickSwitch = true
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}

// MARK: - Text Size Commands

/// Adds message text-zoom items to the View menu: Increase Text Size (⌘+),
/// Reset Text Size (⌥⌘0), and Decrease Text Size (⌘−).
///
/// Each adjusts ``MessageTextScale``, which rescales the conversation text,
/// mention pills, and the compose field together.
struct TextSizeCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Increase Text Size") {
                MessageTextScale.increase()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Reset Text Size") {
                MessageTextScale.reset()
            }
            .keyboardShortcut("0", modifiers: [.option, .command])

            Button("Decrease Text Size") {
                MessageTextScale.decrease()
            }
            .keyboardShortcut("-", modifiers: .command)
        }
    }
}

// MARK: - Notification Delegate

/// Handles notification presentation and user interactions for local notifications.
///
/// When the user taps the verification notification or its "Accept" action,
/// the delegate flips `shouldPresentVerificationSheet` for the verification
/// sheet (arriving with session verification UI).
/// When the user taps a room message notification, the delegate navigates to
/// that room by setting the `selectedRoomId` in `UserDefaults`.
@Observable
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let verificationCategoryIdentifier = "VERIFICATION_REQUEST"
    nonisolated static let acceptActionIdentifier = "ACCEPT_VERIFICATION"
    nonisolated static let roomMessageCategoryIdentifier = "ROOM_MESSAGE"

    weak var client: RelayClient?

    /// Show notifications even when the app is in the foreground.
    ///
    /// When a notification has `.passive` interruption level (set when the user is
    /// actively viewing the room), the banner is suppressed but the sound still plays.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.content.interruptionLevel == .passive {
            return [.sound]
        }
        return [.banner, .sound]
    }

    /// Handle the user tapping a notification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content

        if content.categoryIdentifier == Self.verificationCategoryIdentifier {
            await MainActor.run {
                client?.shouldPresentVerificationSheet = true
            }
            return
        }

        if content.categoryIdentifier == Self.roomMessageCategoryIdentifier {
            let roomId = content.userInfo["roomId"] as? String
            await MainActor.run {
                if let roomId {
                    UserDefaults.standard.set(roomId, forKey: "selectedRoomId")
                }
                NSApp.activate()
                if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                    window.deminiaturize(nil)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            return
        }
    }
}
