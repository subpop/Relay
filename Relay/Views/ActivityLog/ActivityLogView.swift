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
import UniformTypeIdentifiers

/// The root view for the Activity Log window.
///
/// Displays a scrollable table of diagnostic ``ActivityEvent`` entries captured from
/// the service layer, with filtering by category, severity, room, and free-text search.
/// Selecting an event reveals its full detail and metadata in a trailing inspector panel.
struct ActivityLogView: View {
    @Environment(\.activityLog) private var activityLog
    @Environment(RelayClient.self) private var client

    @State private var selectedEventIds: Set<UUID> = []
    @State private var showingInspector = false
    @State private var searchText = ""
    @State private var selectedCategories: Set<ActivityEvent.Category> = Set(ActivityEvent.Category.allCases)
    @State private var minimumSeverity: ActivityEvent.Severity = .debug
    @State private var selectedRoomId: String?
    @State private var isAutoScrollEnabled = true

    private var filteredEvents: [ActivityEvent] {
        activityLog.events.filter { event in
            guard selectedCategories.contains(event.category) else { return false }
            guard event.severity >= minimumSeverity else { return false }
            if let roomFilter = selectedRoomId, event.roomId != roomFilter {
                return false
            }
            if !searchText.isEmpty {
                let roomDisplay = event.roomId.flatMap { roomName(for: $0) } ?? event.roomId ?? ""
                let haystack = "\(event.summary) \(event.detail ?? "") \(event.source) \(roomDisplay)"
                if !haystack.localizedStandardContains(searchText) {
                    return false
                }
            }
            return true
        }
    }

    /// Unique room IDs present in the current event buffer, sorted by display name.
    private var availableRoomIds: [String] {
        Array(Set(activityLog.events.compactMap(\.roomId)))
            .sorted { roomName(for: $0) ?? $0 < roomName(for: $1) ?? $1 }
    }

    /// Returns the display name for a room ID, or `nil` if the room is unknown.
    private func roomName(for roomId: String) -> String? {
        client.rooms.first { $0.roomId.value == roomId }?.displayName
    }

    private var selectedEvents: [ActivityEvent] {
        let ids = selectedEventIds
        return activityLog.events.filter { ids.contains($0.id) }
    }

    private var selectedEvent: ActivityEvent? {
        guard selectedEventIds.count == 1, let id = selectedEventIds.first else { return nil }
        return activityLog.events.first { $0.id == id }
    }

    var body: some View {
        eventTable
            .inspector(isPresented: $showingInspector) {
                detailPane
                    .inspectorColumnWidth(min: 220, ideal: 300, max: 400)
            }
            .searchable(text: $searchText, prompt: "Filter events")
            .toolbar {
                toolbarContent
            }
            .onChange(of: selectedEventIds) { _, newValue in
                if !newValue.isEmpty {
                    showingInspector = true
                }
            }
            .frame(minWidth: 700, minHeight: 400)
    }

    // MARK: - Event Table

    private var eventTable: some View {
        ScrollViewReader { proxy in
            List(filteredEvents, selection: $selectedEventIds) { event in
                ActivityLogRow(event: event, roomName: event.roomId.flatMap { roomName(for: $0) })
                    .tag(event.id)
            }
            .onCopyCommand {
                copySelectedEvents()
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: activityLog.events.count) {
                if isAutoScrollEnabled, let lastId = filteredEvents.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Inspector Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if selectedEventIds.count > 1 {
            ContentUnavailableView(
                "\(selectedEventIds.count) Events Selected",
                systemImage: "doc.on.doc",
                description: Text("Press ⌘C to copy as JSON")
            )
        } else if let event = selectedEvent {
            List {
                Section("Event") {
                    LabeledContent("Timestamp", value: event.formattedTimestamp)
                    LabeledContent("Category") {
                        Label(event.category.label, systemImage: event.category.icon)
                    }
                    LabeledContent("Severity") {
                        Text(event.severity.label)
                            .foregroundStyle(ActivityLogRow.color(for: event.severity))
                    }
                    LabeledContent("Source", value: event.source)
                }

                Section("Summary") {
                    Text(event.summary)
                        .textSelection(.enabled)
                }

                if let roomId = event.roomId {
                    Section("Room") {
                        if let name = roomName(for: roomId) {
                            LabeledContent("Name", value: name)
                        }
                        LabeledContent("ID") {
                            Text(roomId)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                if let detail = event.detail {
                    Section("Detail") {
                        Text(detail)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if !event.metadata.isEmpty {
                    Section("Metadata") {
                        ForEach(event.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(key) {
                                Text(value)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "text.justify.left",
                description: Text("Select an event to view details")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                isAutoScrollEnabled.toggle()
            } label: {
                Label(
                    isAutoScrollEnabled ? "Auto-scroll On" : "Auto-scroll Off",
                    systemImage: isAutoScrollEnabled ? "pause.fill" : "play.fill"
                )
            }
            .help(isAutoScrollEnabled ? "Pause message scrolling" : "Resume message scrolling")
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                Toggle(isOn: Binding(
                    get: { selectedCategories == Set(ActivityEvent.Category.allCases) },
                    set: { isOn in
                        if isOn {
                            selectedCategories = Set(ActivityEvent.Category.allCases)
                        } else {
                            selectedCategories = []
                        }
                    }
                )) {
                    Text("All")
                }

                Divider()

                ForEach(ActivityEvent.Category.allCases) { category in
                    Toggle(isOn: Binding(
                        get: { selectedCategories.contains(category) },
                        set: { isOn in
                            if isOn {
                                selectedCategories.insert(category)
                            } else {
                                selectedCategories.remove(category)
                            }
                        }
                    )) {
                        Label(category.label, systemImage: category.icon)
                    }
                }
            } label: {
                Label("Categories", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filter by category")
        }

        ToolbarItem(placement: .automatic) {
            Picker("Severity", selection: $minimumSeverity) {
                ForEach(ActivityEvent.Severity.allCases) { severity in
                    Text(severity.label).tag(severity)
                }
            }
            .help("Minimum severity level")
        }

        ToolbarItem(placement: .automatic) {
            Picker("Room", selection: $selectedRoomId) {
                Text("All Rooms").tag(String?.none)
                if !availableRoomIds.isEmpty {
                    Divider()
                    ForEach(availableRoomIds, id: \.self) { roomId in
                        Text(roomName(for: roomId) ?? roomId).tag(String?.some(roomId))
                    }
                }
            }
            .help("Filter by room")
        }

        ToolbarItem(placement: .automatic) {
            Button("Clear", systemImage: "trash", role: .destructive) {
                activityLog.clear()
                selectedEventIds = []
            }
            .help("Clear all events")
        }

        ToolbarItem(placement: .automatic) {
            Button("Export", systemImage: "square.and.arrow.up") {
                exportEvents()
            }
            .disabled(filteredEvents.isEmpty)
            .help("Export filtered events as JSON")
            .keyboardShortcut("s", modifiers: .command)
        }

        ToolbarItem(placement: .automatic) {
            Button {
                showingInspector.toggle()
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.trailing")
            }
            .help(showingInspector ? "Hide inspector" : "Show inspector")
        }
    }
    // MARK: - Export

    /// Encodes the selected events as JSON and places them on the pasteboard.
    private func copySelectedEvents() -> [NSItemProvider] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var items: [NSItemProvider] = []
        items.reserveCapacity(selectedEventIds.count)

        for selectedEvent in selectedEvents {
            if let data = try? encoder.encode(selectedEvent),
               let string = String(data: data, encoding: .utf8) {
                items.append(NSItemProvider(object: string as NSString))
            }
        }

        return items
    }

    /// Encodes the currently filtered events as JSON and presents a save panel.
    private func exportEvents() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(filteredEvents) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "relay-activity-log.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

// MARK: - Row View

/// A single row in the activity log event table.
private struct ActivityLogRow: View {
    let event: ActivityEvent
    var roomName: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(event.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            Image(systemName: event.category.icon)
                .foregroundStyle(severityColor)
                .frame(width: 16)

            Circle()
                .fill(severityColor)
                .frame(width: 8, height: 8)

            Text(event.source)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)

            Text(event.summary)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if event.roomId != nil {
                Text(roomName ?? event.roomId!)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
        }
        .padding(.vertical, 1)
    }

    static func color(for severity: ActivityEvent.Severity) -> Color {
        switch severity {
        case .trace: .secondary
        case .debug: .gray
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    private var severityColor: Color {
        Self.color(for: event.severity)
    }
}

// MARK: - Preview

#Preview("Activity Log") {
    let log = ActivityLog()
    log.log(category: .sync, severity: .info, source: "SyncClient", summary: "Sync completed", metadata: ["rooms": "12"])
    log.log(category: .auth, severity: .info, source: "AuthClient", summary: "Session restored from Keychain")
    log.log(category: .network, severity: .warning, source: "NetworkMonitor", summary: "Connectivity lost, retrying", detail: "No route to host")
    log.log(category: .timeline, severity: .error, source: "TimelineViewModel", summary: "Failed to load history", roomId: "!design:matrix.org")
    return ActivityLogView()
        .environment(\.activityLog, log)
        .environment(RelayClient())
        .frame(width: 900, height: 600)
}
