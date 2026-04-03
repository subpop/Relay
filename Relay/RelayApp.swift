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

import RelayKit
import RelayInterface
import SwiftUI
import UserNotifications

/// The main entry point for the Relay macOS application.
///
/// ``RelayApp`` creates the ``MatrixService``, injects it into the SwiftUI environment,
/// manages the dock badge for unread counts, and posts local notifications for new
/// mentions, direct messages, and incoming verification requests.
@main
struct RelayApp: App {
    @State private var matrixService = MatrixService()
    @State private var notificationDelegate = NotificationDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.matrixService, matrixService)
                .environment(\.errorReporter, matrixService.errorReporter)
                .onChange(of: matrixService.rooms.map(\.id)) {
                    updateDockBadge(rooms: matrixService.rooms)
                }
                .onChange(of: matrixService.pendingVerificationRequest?.id) { _, newValue in
                    if newValue != nil, let request = matrixService.pendingVerificationRequest {
                        postVerificationNotification(request: request)
                    }
                }
                .task {
                    await setupNotifications()
                }
        }
        .defaultSize(width: 880, height: 560)

        Settings {
            SettingsView()
                .environment(\.matrixService, matrixService)
                .environment(\.errorReporter, matrixService.errorReporter)
        }
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
        let category = UNNotificationCategory(
            identifier: NotificationDelegate.verificationCategoryIdentifier,
            actions: [acceptAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    private func updateDockBadge(rooms: [RelayInterface.RoomSummary]) {
        let count = rooms.reduce(0 as UInt) { total, room in
            room.isDirect ? total + room.unreadMessages : total + room.unreadMentions
        }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func postNotification(roomName: String, roomId: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = roomName
        content.body = body
        content.sound = .default
        content.threadIdentifier = roomId

        let request = UNNotificationRequest(
            identifier: "room-\(roomId)-\(Date.now.timeIntervalSince1970)",
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

// MARK: - Notification Delegate

/// Handles notification presentation and user interactions for local notifications.
///
/// When the user taps the verification notification or its "Accept" action,
/// the delegate creates a ``SessionVerificationViewModel`` and presents the
/// verification sheet via ``MatrixService/showVerificationSheet``.
@Observable
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let verificationCategoryIdentifier = "VERIFICATION_REQUEST"
    static let acceptActionIdentifier = "ACCEPT_VERIFICATION"

    weak var matrixService: MatrixService?

    /// Show notifications even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Handle the user tapping the notification or the Accept action.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        guard categoryIdentifier == Self.verificationCategoryIdentifier else { return }

        await MainActor.run {
            matrixService?.shouldPresentVerificationSheet = true
        }
    }
}
