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

import SwiftUI

/// The Behavior tab of the Settings window, providing toggles and pickers for
/// privacy, timeline display, and media preferences.
struct SettingsBehaviorTab: View {
    @AppStorage("safety.sendReadReceipts") private var sendReadReceipts = true
    @AppStorage("safety.sendTypingNotifications") private var sendTypingNotifications = true
    @AppStorage("safety.mediaPreviewMode") private var mediaPreviewMode = MediaPreviewMode.privateOnly
    @AppStorage("behavior.showURLPreviews") private var showURLPreviews = true
    @AppStorage("behavior.animateGIFs") private var animateGIFs = GIFAnimationMode.onHover
    @AppStorage("behavior.alwaysLoadNewest") private var alwaysLoadNewest = true
    @AppStorage("behavior.showMembershipEvents") private var showMembershipEvents = true
    @AppStorage("behavior.showStateEvents") private var showStateEvents = true
    @AppStorage("analytics.giphy.optIn") private var giphyAnalyticsOptIn = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $sendReadReceipts) {
                    Text("Send Read Receipts")
                    Text("When disabled, Relay sends a private receipt instead: other members can't see what you've read, but unread counts stay accurate everywhere.")
                }
                Toggle("Send Typing Notifications", isOn: $sendTypingNotifications)
                Toggle(isOn: $giphyAnalyticsOptIn) {
                    Text("Personalize GIF Search Results")
                    Text("When enabled, Relay uses an anonymouse identifier to improve search results sent to GIPHY. When disabled, no identifier is sent at all.")
                    Link("GIPHY Privacy Policy", destination: URL(string: "https://support.giphy.com/hc/en-us/articles/360032872931-GIPHY-Privacy-Policy")!).font(.caption)
                }
            } header: {
                Text("Privacy")
                Text("Public read receipts and typing indicators are visible to other members in a room.")
            } footer: {
            }

            Section {
                Toggle(isOn: $alwaysLoadNewest) {
                    Text("Always Load Newest Messages")
                    Text("When disabled, rooms open at your last read position so you can catch up on missed messages.")
                }
                Toggle("Show Membership & Profile Changes", isOn: $showMembershipEvents)
                Toggle("Show Room State Changes", isOn: $showStateEvents)
            } header: {
                Text("Timeline")
            }

            Section {
                Toggle("Show URL Previews", isOn: $showURLPreviews)

                Picker("Animate GIFs", selection: $animateGIFs) {
                    ForEach(GIFAnimationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker("Show Media Previews In", selection: $mediaPreviewMode) {
                    ForEach(MediaPreviewMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Media")
                Text("Hidden previews can always be revealed by clicking on the media.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - GIF Animation Mode

/// Controls when GIF images animate in the timeline.
enum GIFAnimationMode: String, CaseIterable {
    case always
    case onHover
    case never

    var label: String {
        switch self {
        case .always: "Always"
        case .onHover: "On hover"
        case .never: "Never"
        }
    }
}

// MARK: - Media Preview Mode

enum MediaPreviewMode: String, CaseIterable {
    case allRooms
    case privateOnly

    var label: String {
        switch self {
        case .allRooms: "All rooms"
        case .privateOnly: "Private rooms only"
        }
    }
}

#Preview {
    TabView {
        SettingsBehaviorTab()
            .tabItem { Label("Behavior", systemImage: "gearshape") }
    }
    .frame(width: 480)
}
