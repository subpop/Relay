import RelayCore
import RelaySDK
import SwiftUI
import UserNotifications

/// The main entry point for the Relay macOS application.
///
/// ``RelayApp`` creates the ``MatrixService``, injects it into the SwiftUI environment,
/// manages the dock badge for unread counts, and posts local notifications for new
/// mentions and direct messages.
@main
struct RelayApp: App {
    @State private var matrixService = MatrixService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.matrixService, matrixService)
                .onChange(of: matrixService.rooms.map(\.id)) {
                    updateDockBadge(rooms: matrixService.rooms)
                }
                .task {
                    await requestNotificationPermission()
                }
        }
        .defaultSize(width: 880, height: 560)

        Settings {
            SettingsView()
                .environment(\.matrixService, matrixService)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func updateDockBadge(rooms: [RoomSummary]) {
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
}
