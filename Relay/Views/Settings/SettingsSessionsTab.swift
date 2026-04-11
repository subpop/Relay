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

// MARK: - View Model

@Observable
final class SessionsSettingsViewModel {
    var devices: [DeviceInfo] = []
    var isSessionVerified = false
    var isLoading = true
    var errorReporter: ErrorReporter?

    @MainActor
    func load(service: any MatrixServiceProtocol) async {
        do {
            devices = try await service.getDevices().sorted(by: Self.deviceOrder)
            isSessionVerified = await service.isCurrentSessionVerified()
        } catch {
            errorReporter?.report(.sessionsFailed(error.localizedDescription))
        }
        isLoading = false
    }

    nonisolated static func deviceOrder(_ lhs: DeviceInfo, _ rhs: DeviceInfo) -> Bool {
        if lhs.isCurrentDevice { return true }
        if rhs.isCurrentDevice { return false }
        // swiftlint:disable:next identifier_name
        if let l = lhs.lastSeenTimestamp, let r = rhs.lastSeenTimestamp { return l > r }
        if lhs.lastSeenTimestamp != nil { return true }
        if rhs.lastSeenTimestamp != nil { return false }
        return lhs.id < rhs.id
    }
}

// MARK: - Verification Item

/// A wrapper that gives a session verification view model an `Identifiable`
/// identity for use with `.sheet(item:)`.
struct VerificationItem: Identifiable {
    let id = UUID()
    let viewModel: any SessionVerificationViewModelProtocol
}

// MARK: - Sessions Tab

/// The Sessions tab of the Settings window, listing the current device, other
/// active sessions, and providing a button to start cross-device verification.
struct SettingsSessionsTab: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @State private var viewModel = SessionsSettingsViewModel()
    @State private var verificationItem: VerificationItem?

    var body: some View {
        Form {
            if viewModel.isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            } else if viewModel.devices.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "desktopcomputer",
                        description: Text("No device information is available.")
                    )
                }
            } else {
                let current = viewModel.devices.filter(\.isCurrentDevice)
                let others = viewModel.devices.filter { !$0.isCurrentDevice }

                if let device = current.first {
                    Section("Current Session") {
                        DeviceRow(device: device, isVerified: viewModel.isSessionVerified)
                    }
                }

                if others.count > 0 {
                    Section {
                        Button {
                            Task {
                                do {
                                    // swiftlint:disable:next identifier_name
                                    if let vm = try await matrixService.makeSessionVerificationViewModel() {
                                        verificationItem = VerificationItem(viewModel: vm)
                                    }
                                } catch {
                                    errorReporter.report(.verificationFailed(error.localizedDescription))
                                }
                            }
                        } label: {
                            Label("Verify with Another Device", systemImage: "checkmark.shield")
                        }
                    } footer: {
                        Text("Compare emoji on both devices to confirm your identity.")
                    }
                }

                if !others.isEmpty {
                    Section("Other Sessions") {
                        ForEach(others) { device in
                            DeviceRow(device: device)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            viewModel.errorReporter = errorReporter
            await viewModel.load(service: matrixService)
        }
        .sheet(item: $verificationItem) { item in
            VerificationSheet(viewModel: item.viewModel)
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: DeviceInfo
    var isVerified: Bool?

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        // swiftlint:disable:next identifier_name
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var iconName: String {
        if device.isCurrentDevice {
            return (isVerified == true) ? "checkmark.shield.fill" : "xmark.shield.fill"
        }
        return "desktopcomputer"
    }

    private var iconColor: Color {
        if device.isCurrentDevice {
            return (isVerified == true) ? .green : .red
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName ?? "Unknown device")
                        .fontWeight(.medium)
                    if device.isCurrentDevice {
                        Text("This device")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Text(device.id)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)

                    // swiftlint:disable:next identifier_name
                    if let ts = device.lastSeenTimestamp {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(Self.relativeDateFormatter.localizedString(for: ts, relativeTo: .now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // swiftlint:disable:next identifier_name
                if let ip = device.lastSeenIP {
                    Text(ip)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TabView {
        SettingsSessionsTab()
            .tabItem { Label("Sessions", systemImage: "desktopcomputer") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}
