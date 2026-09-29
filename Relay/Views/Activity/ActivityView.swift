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
import MatrixKit
import SwiftUI

/// The Activity window: connection status, sync mode, session trust,
/// server capabilities, recent moments, and pointers to detailed logging.
///
/// Detailed debug logging lives in the unified system log (see the
/// Diagnostics card), not in this window — this is the at-a-glance
/// overview for "is my session healthy?".
struct ActivityView: View {
    @Environment(RelayClient.self) private var client
    @State private var viewModel: ActivityViewModel?

    var body: some View {
        Group {
            if case .loggedIn = client.authState {
                // Read so the poll loop's bump re-renders relative timestamps.
                let _ = viewModel?.tick
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ActivityHero()
                        ActivitySectionLabel("Status")
                        ActivityCard {
                            ActivityRow(
                                icon: "arrow.triangle.2.circlepath", tint: .blue,
                                label: "Sync Mode",
                                value: client.isUsingSlidingSync
                                    ? "Sliding sync" : "Classic sync")
                            Divider()
                            ActivityRow(
                                icon: "clock", tint: .cyan,
                                label: "Last Sync", value: lastSyncText)
                            Divider()
                            ActivityRow(
                                icon: "key.fill", tint: .orange,
                                label: "One-Time Keys", value: oneTimeKeyText)
                            Divider()
                            ActivityRow(
                                icon: "person.2.fill", tint: .purple,
                                label: "Other Sessions", value: otherSessionsText)
                        }
                        ActivitySectionLabel("Server")
                        ActivityCard {
                            if let homeserver = client.homeserver()?.absoluteString {
                                ActivityRow(
                                    icon: "server.rack", tint: .gray,
                                    label: "Homeserver", value: homeserver,
                                    selectable: true)
                                Divider()
                            }
                            ActivityRow(
                                icon: "info.circle", tint: .blue,
                                label: "Server Version",
                                value: client.newestServerVersion ?? "Unknown")
                            Divider()
                            ActivityRow(
                                icon: "network", tint: .teal,
                                label: "Sliding Sync", value: slidingSupportText)
                            Divider()
                            ActivityRow(
                                icon: "square.stack.3d.up.fill", tint: .gray,
                                label: "Default Room Version",
                                value: viewModel?.capabilities?.defaultRoomVersion
                                    ?? "Unknown")
                            Divider()
                            ActivityRow(
                                icon: "lock.fill", tint: .gray,
                                label: "Account Changes", value: accountChangesText)
                        }
                        ActivitySectionLabel("Recent Activity")
                        ActivityCard {
                            if client.recentActivity.isEmpty {
                                Text("No recent activity yet.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 7)
                            } else {
                                ForEach(
                                    Array(client.recentActivity.reversed().enumerated()),
                                    id: \.element.id
                                ) { index, entry in
                                    if index > 0 {
                                        Divider()
                                    }
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(
                                            entry.timestamp,
                                            format: .dateTime.hour().minute().second())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(minWidth: 60, alignment: .leading)
                                        Text(entry.text)
                                            .font(.callout)
                                    }
                                    .padding(.vertical, 7)
                                }
                            }
                        }
                        ActivitySectionLabel("Diagnostics")
                        ActivityCard {
                            Text("To attach logs to a bug report, run the command below in Terminal while reproducing the issue, then include the captured output.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 7)
                            Text(ActivityDiagnostics.logCommand)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color(nsColor: .textBackgroundColor),
                                    in: .rect(cornerRadius: 6))
                            HStack {
                                Button("Copy Log Command", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        ActivityDiagnostics.logCommand, forType: .string)
                                }
                                Spacer(minLength: 0)
                                Button("Open Console", systemImage: "interface.window") {
                                    _ = NSWorkspace.shared.open(
                                        URL(
                                            fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                                }
                            }
                            .controlSize(.small)
                            .padding(.vertical, 7)
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("Sign in to see session activity."))
            }
        }
        .task {
            let model = ActivityViewModel(client: client)
            viewModel = model
            await model.runPollLoop()
        }
    }

    private var lastSyncText: String {
        client.syncStats.lastSyncAt?.formatted(.relative(presentation: .named)) ?? "Never"
    }

    /// Servers don't advertise a pool size; warn when the remainder is low.
    private var oneTimeKeyText: String {
        guard let count = client.syncStats.lastOneTimeKeyCount else { return "Unknown" }
        return count < 20 ? "\(count) remaining — low" : "\(count) remaining"
    }

    private var otherSessionsText: String {
        guard let counts = viewModel?.deviceCounts else { return "Unknown" }
        guard counts.verified + counts.unverified > 0 else { return "None" }
        return "\(counts.verified) verified • \(counts.unverified) unverified"
    }

    private var slidingSupportText: String {
        switch client.serverSupportsSlidingSync {
        case true: "Supported"
        case false: "Not supported"
        case nil: "Unknown"
        }
    }

    private var accountChangesText: String {
        guard let capabilities = viewModel?.capabilities else { return "Unknown" }
        var restricted: [String] = []
        if !capabilities.canChangePassword { restricted.append("password") }
        if !capabilities.canSetDisplayName { restricted.append("display name") }
        if !capabilities.canSetAvatarURL { restricted.append("avatar") }
        if !capabilities.canChangeThreePIDs { restricted.append("3PIDs") }
        if restricted.isEmpty {
            return "All allowed"
        }
        return "Restricted: \(restricted.joined(separator: ", "))"
    }
}

// MARK: - Hero

/// Connection state banner, tinted by status.
private struct ActivityHero: View {
    @Environment(RelayClient.self) private var client

    var body: some View {
        HStack(spacing: 12) {
            StatusLight(color: status.color, pulsing: status.pulsing, diameter: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.title3)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: status.icon)
                .font(.largeTitle)
                .foregroundStyle(status.color)
        }
        .padding(14)
        .background(status.color.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private var status: (title: String, icon: String, color: Color, pulsing: Bool) {
        switch client.authState {
        case .loggedIn:
            switch client.syncState {
            case .running:
                ("Connected", "checkmark.circle.fill", .green, true)
            case .syncing:
                ("Syncing…", "arrow.triangle.2.circlepath", .blue, true)
            case .offline:
                ("Offline", "wifi.slash", .orange, false)
            case .error:
                ("Sync Error", "exclamationmark.circle.fill", .red, false)
            case .idle:
                ("Idle", "circle", .secondary, false)
            }
        case .loggingIn:
            ("Signing In…", "arrow.triangle.2.circlepath", .blue, true)
        case .loggedOut, .unknown:
            ("Signed Out", "circle", .secondary, false)
        case .error:
            ("Sign-In Error", "exclamationmark.circle.fill", .red, false)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if case .loggedIn = client.authState {
            parts.append(client.isUsingSlidingSync ? "Sliding sync" : "Classic sync")
        }
        if let lastSync = client.syncStats.lastSyncAt {
            parts.append("Last sync \(lastSync.formatted(.relative(presentation: .named)))")
        }
        if case .error(let message) = client.syncState {
            parts.append(message)
        }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Cards and Rows

/// A small-caps section heading above a card.
private struct ActivitySectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.leading, 4)
    }
}

/// A rounded card grouping related rows.
private struct ActivityCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// One labeled row with an icon chip and a trailing value.
private struct ActivityRow: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String
    var selectable: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.15), in: .rect(cornerRadius: 6))
            Text(label)
            Spacer(minLength: 8)
            if selectable {
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Status Light

/// A status indicator dot: steady, or gently pulsing for live states.
/// Pulsing respects Reduce Motion.
private struct StatusLight: View {
    let color: Color
    var pulsing: Bool = false
    var diameter: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .opacity(pulsing && !reduceMotion && glow ? 0.4 : 1)
            .animation(
                .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: glow)
            .onAppear {
                if pulsing && !reduceMotion {
                    glow = true
                }
            }
    }
}

// MARK: - Diagnostics Command

/// The shared log-capture command for bug reports.
private enum ActivityDiagnostics {
    /// Captures Relay + MatrixKit debug traffic.
    static let logCommand = """
        log stream --predicate 'subsystem == "app.subpop.Relay" OR subsystem == "app.subpop.MatrixKit"' --level debug
        """
}

// MARK: - Previews

#Preview("Signed Out") {
    ActivityView()
        .environment(RelayClient())
        .frame(width: 480, height: 600)
}

#Preview("Active") {
    ActivityView()
        .environment({
            let client = RelayClient()
            client.authState = .loggedIn(userId: "@link:example.org")
            client.syncState = .running
            client.isNetworkConnected = true
            var stats = RelayClient.SyncStats()
            stats.record(
                delta: SyncDelta(
                    nextBatch: "s1",
                    toDevice: [BasicEvent(type: "m.dummy")],
                    signedKeyCount: 42),
                at: Date().addingTimeInterval(-30))
            client.syncStats = stats
            client.recentActivity = [
                RelayClient.ActivityEntry(text: "Device keys published"),
                RelayClient.ActivityEntry(text: "Initial sync completed"),
                RelayClient.ActivityEntry(text: "Connectivity restored"),
            ]
            return client
        }())
        .frame(width: 480, height: 600)
}
