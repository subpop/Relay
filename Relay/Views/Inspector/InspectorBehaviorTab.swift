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

/// The Behavior tab of the timeline inspector, showing per-room overrides for
/// display preferences like GIF animation, media previews, URL previews, and
/// timeline event filtering.
struct InspectorBehaviorTab: View {
    let roomId: String

    @State private var overrides: RoomBehaviorOverrides = .init()
    @AppStorage("behavior.animateGIFs") private var globalAnimateGIFs = GIFAnimationMode.onHover
    @AppStorage("behavior.showURLPreviews") private var globalShowURLPreviews = true
    @AppStorage("behavior.showMembershipEvents") private var globalShowMembershipEvents = true
    @AppStorage("behavior.showStateEvents") private var globalShowStateEvents = true

    private let store = RoomBehaviorStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                mediaSection
                timelineEventsSection
                resetSection
            }
            .padding(.vertical)
        }
        .onAppear {
            overrides = store.overrides(for: roomId)
        }
    }

    // MARK: - Media

    private var mediaSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                BehaviorOverrideToggle(
                    label: "Show Media Previews",
                    icon: "photo",
                    override: $overrides.showMediaPreviews,
                    globalDefault: true,
                    globalLabel: "Default"
                )
                .padding(.leading, 8)
                .onChange(of: overrides.showMediaPreviews) { persist() }

                Divider()

                BehaviorOverridePicker(
                    label: "Animate GIFs",
                    icon: "play.circle",
                    override: $overrides.animateGIFs,
                    globalDefault: globalAnimateGIFs.rawValue,
                    options: GIFAnimationMode.allCases.map { ($0.rawValue, $0.label) }
                )
                .padding(.leading, 8)
                .onChange(of: overrides.animateGIFs) { persist() }

                Divider()

                BehaviorOverrideToggle(
                    label: "Show URL Previews",
                    icon: "link",
                    override: $overrides.showURLPreviews,
                    globalDefault: globalShowURLPreviews,
                    globalLabel: globalShowURLPreviews ? "On" : "Off"
                )
                .padding(.leading, 8)
                .onChange(of: overrides.showURLPreviews) { persist() }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Media & Links", systemImage: "photo.on.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Timeline Events

    private var timelineEventsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                BehaviorOverrideToggle(
                    label: "Show Join & Part Events",
                    icon: "person.badge.plus",
                    override: $overrides.showMembershipEvents,
                    globalDefault: globalShowMembershipEvents,
                    globalLabel: globalShowMembershipEvents ? "Shown" : "Hidden"
                )
                .padding(.leading, 8)
                .onChange(of: overrides.showMembershipEvents) { persist() }

                Divider()

                BehaviorOverrideToggle(
                    label: "Show Name Changes",
                    icon: "textformat.alt",
                    override: $overrides.showStateEvents,
                    globalDefault: globalShowStateEvents,
                    globalLabel: globalShowStateEvents ? "Shown" : "Hidden"
                )
                .padding(.leading, 8)
                .onChange(of: overrides.showStateEvents) { persist() }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Timeline Events", systemImage: "list.bullet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Reset

    private var resetSection: some View {
        Group {
            if !overrides.isEmpty {
                Button("Restore All Defaults", systemImage: "arrow.uturn.backward") {
                    overrides = RoomBehaviorOverrides()
                    persist()
                }
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Persistence

    private func persist() {
        store.setOverrides(overrides, for: roomId)
    }
}

// MARK: - Behavior Override Toggle

/// A toggle row that supports a tri-state: use global default (`nil`) or an explicit override.
///
/// When the override is `nil`, shows "Default (On/Off)" as the current value. Clicking the
/// toggle switches to an explicit override. A reset button restores the global default.
private struct BehaviorOverrideToggle: View {
    let label: String
    let icon: String
    @Binding var override: Bool?
    let globalDefault: Bool
    let globalLabel: String

    private var effectiveValue: Bool {
        override ?? globalDefault
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { effectiveValue },
                set: { override = $0 }
            )) {
                Label(label, systemImage: icon)
                    .font(.callout)
            }

            HStack(spacing: 4) {
                if override != nil {
                    Text("Overridden")
                        .font(.caption2)
                        .foregroundStyle(.tint)

                    Button("Reset") {
                        override = nil
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Using default (\(globalLabel))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Behavior Override Picker

/// A picker row that supports an optional override with fallback to a global default.
private struct BehaviorOverridePicker: View {
    let label: String
    let icon: String
    @Binding var override: String?
    let globalDefault: String
    let options: [(value: String, label: String)]

    private var effectiveValue: String {
        override ?? globalDefault
    }

    private var globalLabel: String {
        options.first { $0.value == globalDefault }?.label ?? globalDefault
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(
                get: { effectiveValue },
                set: { override = $0 }
            )) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                Label(label, systemImage: icon)
                    .font(.callout)
            }

            HStack(spacing: 4) {
                if override != nil {
                    Text("Overridden")
                        .font(.caption2)
                        .foregroundStyle(.tint)

                    Button("Reset") {
                        override = nil
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Using default (\(globalLabel))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

#Preview {
    InspectorBehaviorTab(roomId: "!design:matrix.org")
        .frame(width: 280, height: 600)
}
