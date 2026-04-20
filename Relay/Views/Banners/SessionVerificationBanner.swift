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

/// A compact banner shown at the bottom of the sidebar when the current session
/// has not been verified or when an incoming verification request is pending.
///
/// Shows two modes:
/// - **Incoming request**: When another device has sent a verification request,
///   displays Accept and Decline buttons so the user can respond without relying
///   on the system notification.
/// - **Unverified**: When no request is pending but the session is unverified,
///   shows a "Verify" button to initiate verification and a dismiss button.
struct SessionVerificationBanner: View {
    @Environment(\.matrixService) private var matrixService
    @Binding var verificationItem: VerificationItem?
    @State private var isDismissed = false
    @State private var bannerWidth: CGFloat = 0

    /// Width threshold below which the banner switches to compact layout.
    private static let compactThreshold: CGFloat = 180

    /// Whether the banner should display in compact mode.
    private var isCompact: Bool {
        bannerWidth < Self.compactThreshold
    }

    /// Whether the banner should be visible.
    private var isVisible: Bool {
        if matrixService.pendingVerificationRequest != nil {
            return true
        }
        return matrixService.hasCheckedVerificationState
            && !matrixService.isSessionVerified
            && !isDismissed
    }

    var body: some View {
        if isVisible {
            Group {
                if matrixService.pendingVerificationRequest != nil {
                    incomingRequestContent
                } else {
                    unverifiedContent
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isCompact ? 12 : 8)
            .frame(maxWidth: .infinity)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tintColor.opacity(0.12))
                    .allowsHitTesting(false)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newValue in
                bannerWidth = newValue
            }
            .animation(.default, value: isCompact)
        }
    }

    private var tintColor: Color {
        matrixService.pendingVerificationRequest != nil ? .blue : .orange
    }

    // MARK: - Incoming Request

    private var incomingRequestContent: some View {
        Group {
            if isCompact {
                compactIncomingRequestContent
            } else {
                regularIncomingRequestContent
            }
        }
    }

    private var regularIncomingRequestContent: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.blue)
                    .font(.body)
                Text(
                    matrixService.pendingVerificationRequest
                        .map { "Request from device \($0.deviceId)" }
                        ?? "Verification Request"
                )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }

            Button(role: .destructive) {
                Task { await matrixService.declinePendingVerificationRequest() }
            } label: {
                Image(systemName: "xmark")
            }
            .controlSize(.small)

            Button {
                Task {
                    // swiftlint:disable:next identifier_name
                    if let vm = try? await matrixService.makeSessionVerificationViewModel() {
                        matrixService.pendingVerificationRequest = nil
                        verificationItem = VerificationItem(viewModel: vm)
                    }
                }
            } label: {
                Image(systemName: "checkmark")
            }
            .controlSize(.small)
        }
    }

    private var compactIncomingRequestContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 36))

            Button("Decline", systemImage: "xmark", role: .destructive) {
                Task { await matrixService.declinePendingVerificationRequest() }
            }
            .controlSize(.small)

            Button("Approve", systemImage: "checkmark") {
                Task {
                    // swiftlint:disable:next identifier_name
                    if let vm = try? await matrixService.makeSessionVerificationViewModel() {
                        matrixService.pendingVerificationRequest = nil
                        verificationItem = VerificationItem(viewModel: vm)
                    }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Unverified Session

    private var unverifiedContent: some View {
        Group {
            if isCompact {
                compactUnverifiedContent
            } else {
                regularUnverifiedContent
            }
        }
    }

    private var regularUnverifiedContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.body)

            VStack(alignment: .leading, spacing: 1) {
                Text("Session Not Verified")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Spacer(minLength: 4)

            Button("Verify") {
                Task {
                    // swiftlint:disable:next identifier_name
                    if let vm = try? await matrixService.makeSessionVerificationViewModel() {
                        verificationItem = VerificationItem(viewModel: vm)
                    }
                }
            }
            .controlSize(.small)

            Button {
                isDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    private var compactUnverifiedContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 36))

            Button("Verify") {
                Task {
                    // swiftlint:disable:next identifier_name
                    if let vm = try? await matrixService.makeSessionVerificationViewModel() {
                        verificationItem = VerificationItem(viewModel: vm)
                    }
                }
            }
            .controlSize(.small)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                isDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .offset(x: 16, y: -4)
        }
    }
}

// MARK: - Previews

#Preview("Incoming Request") {
    @Previewable @State var verificationItem: VerificationItem?
    let service = PreviewMatrixService()
    service.isSessionVerified = false
    service.pendingVerificationRequest = IncomingVerificationRequest(
        deviceId: "ABCDEF1234",
        senderId: "@alice:matrix.org",
        flowId: "preview-flow"
    )
    return VStack {
        Spacer()
        SessionVerificationBanner(verificationItem: $verificationItem)
    }
    .environment(\.matrixService, service)
    .frame(width: 280, height: 200)
}

#Preview("Incoming Request (Compact)") {
    @Previewable @State var verificationItem: VerificationItem?
    let service = PreviewMatrixService()
    service.isSessionVerified = false
    service.pendingVerificationRequest = IncomingVerificationRequest(
        deviceId: "ABCDEF1234",
        senderId: "@alice:matrix.org",
        flowId: "preview-flow"
    )
    return VStack {
        Spacer()
        SessionVerificationBanner(verificationItem: $verificationItem)
    }
    .environment(\.matrixService, service)
    .frame(width: 116, height: 200)
}

#Preview("Unverified") {
    @Previewable @State var verificationItem: VerificationItem?
    let service = PreviewMatrixService()
    service.isSessionVerified = false
    return VStack {
        Spacer()
        SessionVerificationBanner(verificationItem: $verificationItem)
    }
    .environment(\.matrixService, service)
    .frame(width: 280, height: 200)
}

#Preview("Unverified (Compact)") {
    @Previewable @State var verificationItem: VerificationItem?
    let service = PreviewMatrixService()
    service.isSessionVerified = false
    return VStack {
        Spacer()
        SessionVerificationBanner(verificationItem: $verificationItem)
    }
    .environment(\.matrixService, service)
    .frame(width: 116, height: 200)
}

#Preview("Verified") {
    @Previewable @State var verificationItem: VerificationItem?
    SessionVerificationBanner(verificationItem: $verificationItem)
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 200)
}
