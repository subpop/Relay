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

/// The Notifications tab of the timeline inspector, showing per-room notification settings.
struct InspectorNotificationsTab: View {
    let viewModel: TimelineInspectorViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if viewModel.isLoadingNotifications {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    notificationContent
                }
            }
            .padding(.vertical)
        }
        .task {
            await viewModel.loadNotificationSettings()
        }
    }

    // MARK: - Content

    private var notificationContent: some View {
        VStack(spacing: 20) {
            modeSection
            defaultSection
        }
    }

    // MARK: - Mode Selection

    private var modeSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(
                    RoomNotificationMode.allCases.enumerated(),
                    id: \.element
                ) { index, mode in
                    if index > 0 {
                        Divider().padding(.vertical, 4)
                    }
                    NotificationModeRow(
                        mode: mode,
                        isSelected: viewModel.roomNotificationMode == mode,
                        action: { viewModel.setNotificationMode(mode) }
                    )
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Notification Level", systemImage: "bell")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Default Section

    private var defaultSection: some View {
        GroupBox {
            VStack(spacing: 8) {
                if viewModel.isNotificationDefault {
                    Label("Using default settings", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        Text("Custom override active")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Default") {
                            viewModel.restoreDefaultNotifications()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Default", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}

// MARK: - Notification Mode Row

private struct NotificationModeRow: View {
    let mode: RoomNotificationMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.label)
                        .font(.callout)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension RoomNotificationMode {
    var description: String {
        switch self {
        case .allMessages: "Get notified for every message"
        case .mentionsAndKeywordsOnly: "Only when you are mentioned"
        case .mute: "No notifications from this room"
        }
    }
}

#Preview {
    InspectorNotificationsTab(viewModel: .preview())
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 600)
}
