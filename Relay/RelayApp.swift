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

import os
import RelayKit
import RelayInterface
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "Relay", category: "DeepLink")

/// The main entry point for the Relay macOS application.
///
/// ``RelayApp`` creates the ``MatrixService``, injects it into the SwiftUI environment,
/// manages the dock badge for unread counts, and posts local notifications for new
/// mentions, direct messages, and incoming verification requests.
@main
struct RelayApp: App {
    @State private var matrixService = MatrixService()
    @State private var gifSearchService = GiphyService(apiKey: Secrets.giphyAPIKey ?? "")
    @State private var callManager = CallManager()
    @State private var notificationDelegate = NotificationDelegate()
    @State private var appActions = AppActions()
    @State private var showClearCacheConfirmation = false

    @Environment(\.openWindow) private var openWindow

    @AppStorage("selectedRoomId") private var selectedRoomId: String?

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(\.matrixService, matrixService)
                .environment(\.gifSearchService, gifSearchService)
                .environment(\.callManager, callManager)
                .environment(\.errorReporter, matrixService.errorReporter)
                .environment(appActions)
                .onChange(of: dockBadgeCount) { _, newCount in
                    NSApp.dockTile.badgeLabel = newCount > 0 ? "\(newCount)" : nil
                }
                .onChange(of: matrixService.pendingVerificationRequest?.id) { _, newValue in
                    if newValue != nil, let request = matrixService.pendingVerificationRequest {
                        postVerificationNotification(request: request)
                    }
                }
                .onOpenURL { url in
                    if let uri = MatrixURI(url: url) {
                        logger.info("Received deep link: \(url.absoluteString)")
                        matrixService.pendingDeepLink = uri
                    }
                }
                .task {
                    await setupNotifications()
                    matrixService.onNotificationEvent = { event in
                        Task { @MainActor in
                            self.handleNotificationEvent(event)
                        }
                    }
                }
                .alert("Clear Cache", isPresented: $showClearCacheConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear Cache", role: .destructive) {
                        Task { await matrixService.clearLocalData() }
                    }
                } message: {
                    Text("This will delete all locally cached data and resync from the server. You will remain logged in.")
                }
        }
        .defaultSize(width: 880, height: 560)
        .commands {
            FileMenuCommands(appActions: appActions)
            EditLastMessageCommand()
            SidebarCommands()
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
                        NSApplication.shared.activate()
                    } else {
                        openWindow(id: "main")
                    }
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(\.matrixService, matrixService)
                .environment(\.gifSearchService, gifSearchService)
                .environment(\.errorReporter, matrixService.errorReporter)
        }

        Window("Call", id: "call") {
            CallWindowView()
                .environment(\.matrixService, matrixService)
                .environment(\.callManager, callManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 360, height: 540)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(.suppressed)
    }

    // MARK: - Notifications

    private func setupNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        notificationDelegate.matrixService = matrixService
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
    /// Because ``RoomSummary`` is `@Observable`, SwiftUI tracks each property
    /// access and re-evaluates this whenever any room's unread state changes.
    /// The count respects each room's effective notification mode:
    /// - All Messages: counts all unread messages
    /// - Mentions & Keywords Only: counts only unread mentions
    /// - Mute: counts nothing
    private var dockBadgeCount: UInt {
        matrixService.rooms.reduce(0 as UInt) { total, room in
            switch room.notificationMode {
            case .mute:
                return total
            case .mentionsAndKeywordsOnly:
                return total + room.unreadMentions
            case .allMessages:
                return total + room.unreadMessages
            case nil:
                // Default: DMs count all messages, groups count mentions only
                return room.isDirect ? total + room.unreadMessages : total + room.unreadMentions
            }
        }
    }

    /// Handles a notification event from the room list manager.
    ///
    /// Posts a system notification banner and/or plays a sound when a room has new
    /// unread activity, respecting the room's effective notification mode:
    /// - **All Messages**: sound + banner for every message.
    /// - **Mentions & Keywords Only**: sound + banner only for mentions.
    /// - **Mute**: no sound or banner.
    /// - **Default** (`nil`): DMs behave as All Messages; groups as Mentions & Keywords Only.
    ///
    /// When the user is actively viewing the room, the banner is suppressed but
    /// the sound still plays (if warranted by the notification mode).
    private func handleNotificationEvent(_ event: RoomNotificationEvent) {
        // Determine the effective notification mode for this room.
        // When there is no per-room override, DMs default to "All Messages"
        // and groups default to "Mentions & Keywords Only".
        let effectiveMode: RelayInterface.RoomNotificationMode = event.notificationMode
            ?? (event.isDirect ? .allMessages : .mentionsAndKeywordsOnly)

        // Muted rooms produce no sound, banner, or other system notification.
        guard effectiveMode != .mute else { return }

        // For "Mentions & Keywords Only", only notify when the message is a mention.
        if effectiveMode == .mentionsAndKeywordsOnly, !event.isMention {
            return
        }

        let content = UNMutableNotificationContent()

        if event.isDirect {
            content.title = event.roomName
        } else {
            content.title = "\(event.messageAuthor ?? "Unknown sender") in \(event.roomName)"
        }

        content.body = event.messageBody ?? "New message"
        content.sound = .default
        content.threadIdentifier = event.roomId
        content.userInfo = ["roomId": event.roomId]
        content.categoryIdentifier = NotificationDelegate.roomMessageCategoryIdentifier

        // Suppress the banner when the user is actively viewing this room,
        // but still deliver the notification so the sound plays.
        if NSApp.isActive, selectedRoomId == event.roomId {
            content.interruptionLevel = .passive
        }

        let request = UNNotificationRequest(
            identifier: "room-\(event.roomId)-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postVerificationNotification(request: IncomingVerificationRequest) {
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
    var showJoinRoom = false
    var showRoomDirectory = false
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
/// The command reads the ``EditLastMessageKey`` focused value published by
/// ``TimelineView``.  When a timeline is focused and contains at least one
/// outgoing text message, pressing ⌘E starts editing that message.
struct EditLastMessageCommand: Commands {
    @FocusedValue(\.editLastMessage) private var editLastMessage

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Edit Last Message") {
                editLastMessage?()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(editLastMessage == nil)
        }
    }
}

// MARK: - Notification Delegate

/// Handles notification presentation and user interactions for local notifications.
///
/// When the user taps the verification notification or its "Accept" action,
/// the delegate creates a ``SessionVerificationViewModel`` and presents the
/// verification sheet via ``MatrixService/showVerificationSheet``.
/// When the user taps a room message notification, the delegate navigates to
/// that room by setting the `selectedRoomId` in `UserDefaults`.
@Observable
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let verificationCategoryIdentifier = "VERIFICATION_REQUEST"
    nonisolated static let acceptActionIdentifier = "ACCEPT_VERIFICATION"
    nonisolated static let roomMessageCategoryIdentifier = "ROOM_MESSAGE"

    weak var matrixService: MatrixService?

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
                matrixService?.shouldPresentVerificationSheet = true
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
