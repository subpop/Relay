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

import RelayInterface
import SwiftUI

/// A slide-in panel that displays a user's profile within the Members tab.
///
/// Shows the user's avatar, display name, Matrix ID, role badge, a "Message" button
/// for opening a DM, info section, and moderation actions (mute, kick, ban, ignore).
struct MemberDetailPanel: View {
    let profile: UserProfile
    let roomId: String

    /// Called when the user taps the "Message" button to open a DM.
    var onMessageTap: (() -> Void)?

    /// Called when the user taps the back button to return to the member list.
    var onBack: () -> Void

    /// Called after a kick or ban succeeds, so the parent can refresh.
    var onModerationAction: (() -> Void)?

    @Environment(\.matrixService) private var matrixService
    @State private var isIgnored = false
    @State private var isPerformingAction = false
    @State private var confirmationAction: ModerationAction?

    private var isSelf: Bool {
        profile.userId == matrixService.userId()
    }

    private var name: String {
        profile.displayName ?? profile.userId
    }

    var body: some View {
        VStack(spacing: 0) {
            backHeader

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    headerSection

                    if !isSelf, let onMessageTap {
                        Button("Message", systemImage: "bubble.left.fill", action: onMessageTap)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal)
                    }

                    infoSection

                    if !isSelf {
                        actionsSection
                    }
                }
                .padding(.vertical)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(isPerformingAction)
        .task {
            isIgnored = (try? await matrixService.isUserIgnored(userId: profile.userId)) ?? false
        }
        .confirmationDialog(
            confirmationAction?.title ?? "",
            isPresented: Binding(
                get: { confirmationAction != nil },
                set: { if !$0 { confirmationAction = nil } }
            ),
            presenting: confirmationAction
        ) { action in
            Button(action.confirmLabel, role: .destructive) {
                performAction(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message(for: name))
        }
    }

    // MARK: - Back Header

    private var backHeader: some View {
        HStack {
            Button(action: onBack) {
                Label("Members", systemImage: "chevron.left")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            AvatarView(name: name, mxcURL: profile.avatarURL, size: 80)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

            Text(name)
                .font(.title3)
                .bold()

            Text(profile.userId)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let role = profile.role, role != .user {
                MemberRoleBadge(role: role)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Info

    private var infoSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                InspectorInfoRow(label: "Matrix ID", value: profile.userId)

                if let displayName = profile.displayName {
                    Divider().padding(.vertical, 4)
                    InspectorInfoRow(label: "Display Name", value: displayName)
                }

                if let powerLevel = profile.powerLevel {
                    Divider().padding(.vertical, 4)
                    InspectorInfoRow(label: "Power Level", value: "\(powerLevel)")
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Info", systemImage: "person.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                ModerationButton(
                    label: isIgnored ? "Unignore User" : "Ignore User",
                    icon: isIgnored ? "eye" : "eye.slash",
                    color: .secondary
                ) {
                    confirmationAction = isIgnored ? .unignore : .ignore
                }

                Divider().padding(.vertical, 4)

                ModerationButton(
                    label: "Kick from Room",
                    icon: "door.left.hand.open",
                    color: .orange
                ) {
                    confirmationAction = .kick
                }

                Divider().padding(.vertical, 4)

                ModerationButton(
                    label: "Ban from Room",
                    icon: "xmark.shield",
                    color: .red
                ) {
                    confirmationAction = .ban
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Action Handling

    private func performAction(_ action: ModerationAction) {
        isPerformingAction = true
        Task {
            defer { isPerformingAction = false }
            do {
                switch action {
                case .kick:
                    try await matrixService.kickMember(
                        roomId: roomId, userId: profile.userId, reason: nil
                    )
                    onModerationAction?()
                case .ban:
                    try await matrixService.banMember(
                        roomId: roomId, userId: profile.userId, reason: nil
                    )
                    onModerationAction?()
                case .ignore:
                    try await matrixService.ignoreUser(userId: profile.userId)
                    isIgnored = true
                case .unignore:
                    try await matrixService.unignoreUser(userId: profile.userId)
                    isIgnored = false
                }
            } catch {
                // Errors are silently handled; a future enhancement could surface these.
            }
        }
    }
}

// MARK: - Moderation Action

private enum ModerationAction: Identifiable {
    case kick, ban, ignore, unignore

    var id: String {
        switch self {
        case .kick: "kick"
        case .ban: "ban"
        case .ignore: "ignore"
        case .unignore: "unignore"
        }
    }

    var title: String {
        switch self {
        case .kick: "Kick User"
        case .ban: "Ban User"
        case .ignore: "Ignore User"
        case .unignore: "Unignore User"
        }
    }

    var confirmLabel: String {
        switch self {
        case .kick: "Kick"
        case .ban: "Ban"
        case .ignore: "Ignore"
        case .unignore: "Unignore"
        }
    }

    func message(for name: String) -> String {
        switch self {
        case .kick:
            "Remove \(name) from this room. They can rejoin if invited."
        case .ban:
            "Ban \(name) from this room. They will not be able to rejoin until unbanned."
        case .ignore:
            "Ignore \(name). Their messages will be hidden across all rooms."
        case .unignore:
            "Stop ignoring \(name). Their messages will be visible again."
        }
    }
}

// MARK: - Moderation Button

private struct ModerationButton: View {
    let label: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(label)
                    .font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MemberDetailPanel(
        profile: UserProfile(
            userId: "@alice:matrix.org",
            displayName: "Alice Smith",
            role: .administrator,
            powerLevel: 100
        ),
        roomId: "!design:matrix.org",
        onMessageTap: { print("Message tapped") },
        onBack: { print("Back tapped") }
    )
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 260, height: 600)
}
