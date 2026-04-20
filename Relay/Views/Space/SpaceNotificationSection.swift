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

/// A Form section that displays notification mode controls for a space.
///
/// Allows the user to choose between All Messages, Mentions Only, or Mute
/// for the space room itself. The selection is persisted via the Matrix
/// push rules system through ``MatrixServiceProtocol``.
struct SpaceNotificationSection: View {
    @Environment(\.matrixService) private var matrixService

    let spaceId: String
    @Binding var notificationMode: RoomNotificationMode?
    @Binding var isLoading: Bool

    var body: some View {
        Section("Notifications") {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            } else {
                ForEach(RoomNotificationMode.allCases, id: \.self) { mode in
                    NotificationModeButton(
                        mode: mode,
                        isSelected: notificationMode == mode,
                        action: { setMode(mode) }
                    )
                }

                if notificationMode != nil {
                    Button("Restore Default", systemImage: "arrow.uturn.backward") {
                        restoreDefault()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setMode(_ mode: RoomNotificationMode) {
        let previousMode = notificationMode
        notificationMode = mode
        Task {
            do {
                try await matrixService.setRoomNotificationMode(roomId: spaceId, mode: mode)
            } catch {
                notificationMode = previousMode
            }
        }
    }

    private func restoreDefault() {
        let previousMode = notificationMode
        notificationMode = nil
        Task {
            do {
                try await matrixService.restoreDefaultRoomNotificationMode(roomId: spaceId)
            } catch {
                notificationMode = previousMode
            }
        }
    }
}

// MARK: - Notification Mode Button

/// A selectable row representing a notification mode option.
private struct NotificationModeButton: View {
    let mode: RoomNotificationMode
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .foregroundStyle(.primary)
                    Text(modeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.callout)
                        .bold()
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var modeDescription: String {
        switch mode {
        case .allMessages: "Notify for every message in this space."
        case .mentionsAndKeywordsOnly: "Only notify for mentions and keywords."
        case .mute: "Silence all notifications from this space."
        }
    }
}

// MARK: - Previews

#Preview {
    Form {
        SpaceNotificationSection(
            spaceId: "!space-work:matrix.org",
            notificationMode: .constant(.allMessages),
            isLoading: .constant(false)
        )
    }
    .formStyle(.grouped)
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 600, height: 300)
}

#Preview("Muted") {
    Form {
        SpaceNotificationSection(
            spaceId: "!space-work:matrix.org",
            notificationMode: .constant(.mute),
            isLoading: .constant(false)
        )
    }
    .formStyle(.grouped)
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 600, height: 300)
}
