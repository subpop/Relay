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

/// The context in which the inspector is being used.
enum InspectorContext {
    /// Inspecting a regular room (shown alongside the timeline).
    case room
    /// Inspecting a space (shown alongside the space detail view).
    case space
}

/// The tabs available in the timeline inspector, displayed as an icon-only segmented control.
enum InspectorTab: String, CaseIterable, Identifiable {
    case general
    case members
    case behavior
    case notifications
    case security
    case roles
    case settings

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "info.circle"
        case .members: "person.2"
        case .behavior: "slider.horizontal.3"
        case .notifications: "bell"
        case .security: "lock.shield"
        case .roles: "crown"
        case .settings: "gearshape"
        }
    }

    var label: String {
        switch self {
        case .general: "General"
        case .members: "Members"
        case .behavior: "Behavior"
        case .notifications: "Notifications"
        case .security: "Security & Privacy"
        case .roles: "Roles & Permissions"
        case .settings: "Settings"
        }
    }

    /// Whether this tab is available in the given inspector context.
    func supports(_ context: InspectorContext) -> Bool {
        switch self {
        case .general, .members, .notifications:
            true
        case .behavior, .security, .roles:
            context == .room
        case .settings:
            context == .space
        }
    }

    /// Returns the tabs available for the given context.
    static func tabs(for context: InspectorContext) -> [InspectorTab] {
        allCases.filter { $0.supports(context) }
    }
}

/// An inspector panel that displays detailed room or space information organized into
/// Xcode-style icon-only segmented tabs. The available tabs depend on the ``InspectorContext``:
/// rooms show all six tabs, while spaces show General, Members, Notifications, and Settings.
struct TimelineInspectorView: View {
    @Environment(\.matrixService) private var matrixService

    let roomId: String
    let context: InspectorContext

    /// Called when the user taps the "Message" button on a member's detail panel.
    var onMessageUser: ((String) -> Void)?

    /// Called when a pinned message row is tapped to scroll the timeline.
    var onScrollToMessage: ((String) -> Void)?

    /// A profile selected externally (e.g. by tapping a `matrix.to` user link).
    /// When set, the inspector switches to the Members tab and shows this user's
    /// detail panel. The binding is cleared once the profile has been consumed.
    @Binding var selectedProfile: UserProfile?

    /// The initially selected tab. When `.settings`, the inspector opens directly
    /// to the Settings tab (used when the "Settings" button in ``SpaceDetailView``
    /// is tapped). The binding is cleared after being consumed.
    @Binding var initialTab: InspectorTab?

    @State private var viewModel: TimelineInspectorViewModel
    @State private var selectedTab: InspectorTab = .general

    private var availableTabs: [InspectorTab] {
        InspectorTab.tabs(for: context)
    }

    init(
        roomId: String,
        context: InspectorContext = .room,
        selectedProfile: Binding<UserProfile?> = .constant(nil),
        initialTab: Binding<InspectorTab?> = .constant(nil),
        onMessageUser: ((String) -> Void)? = nil,
        onScrollToMessage: ((String) -> Void)? = nil
    ) {
        self.roomId = roomId
        self.context = context
        self._selectedProfile = selectedProfile
        self._initialTab = initialTab
        self.onMessageUser = onMessageUser
        self.onScrollToMessage = onScrollToMessage
        self._viewModel = State(initialValue: TimelineInspectorViewModel(roomId: roomId, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()

            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.load(service: matrixService)
        }
        .onChange(of: selectedProfile) { _, profile in
            if profile != nil {
                selectedTab = .members
            }
        }
        .onChange(of: initialTab) { _, tab in
            if let tab {
                selectedTab = tab
                initialTab = nil
            }
        }
        .onAppear {
            if let tab = initialTab {
                selectedTab = tab
                initialTab = nil
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        InspectorTabBar(selection: $selectedTab, tabs: availableTabs)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            InspectorGeneralTab(
                viewModel: viewModel,
                context: context,
                onPinnedMessageTap: onScrollToMessage
            )
        case .members:
            InspectorMembersTab(
                viewModel: viewModel,
                context: context,
                selectedProfile: $selectedProfile,
                onMessageUser: onMessageUser
            )
        case .behavior:
            InspectorBehaviorTab(roomId: roomId)
        case .notifications:
            InspectorNotificationsTab(viewModel: viewModel)
        case .security:
            InspectorSecurityTab(viewModel: viewModel)
        case .roles:
            InspectorRolesTab(viewModel: viewModel)
        case .settings:
            InspectorSettingsTab(viewModel: viewModel)
        }
    }
}

#Preview("Room") {
    TimelineInspectorView(roomId: "!design:matrix.org", context: .room)
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 600)
}

#Preview("Space") {
    TimelineInspectorView(roomId: "!space-work:matrix.org", context: .space)
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 600)
}
