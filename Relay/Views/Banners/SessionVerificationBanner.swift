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

/// A compact banner shown at the bottom of the sidebar when the current session
/// has not been verified or when an incoming verification request is pending.
///
/// Shows two modes:
/// - **Incoming request**: When another device has sent a verification request,
///   displays Accept and Decline buttons so the user can respond without relying
///   on the system notification.
/// - **Unverified**: When no request is pending but the session is unverified,
///   shows a "Verify" button to initiate verification and a dismiss button.
///
/// Accepting or starting verification flips
/// `shouldPresentVerificationSheet`; the verification sheet itself
/// arrives with session verification UI.
struct SessionVerificationBanner: View {
    @Environment(RelayClient.self) private var client
    @State private var isDismissed = false
    @Environment(\.hasSpaceRail) private var hasSpaceRail
    @State private var bannerWidth: CGFloat = 0

    /// Width threshold below which the banner switches to compact layout.
    private static let compactThreshold: CGFloat = 140

    /// Whether the banner should display in compact mode.
    private var isCompact: Bool {
        let effectiveWidth = hasSpaceRail ? bannerWidth : bannerWidth - SpaceRail.width
        return effectiveWidth < Self.compactThreshold
    }

    /// Whether the banner should be visible.
    private var isVisible: Bool {
        if client.pendingVerificationRequest != nil {
            return true
        }
        return client.hasCheckedVerificationState
            && !client.isSessionVerified
            && !isDismissed
    }

    var body: some View {
        if isVisible {
            Group {
                if client.pendingVerificationRequest != nil {
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
        client.pendingVerificationRequest != nil ? .blue : .orange
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
                    client.pendingVerificationRequest
                        .map { "Request from device \($0.deviceId)" }
                        ?? "Verification Request"
                )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }

            Button(role: .destructive) {
                Task { await client.declinePendingVerificationRequest() }
            } label: {
                Image(systemName: "xmark")
            }
            .controlSize(.small)

            Button {
                client.shouldPresentVerificationSheet = true
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
                Task { await client.declinePendingVerificationRequest() }
            }
            .controlSize(.small)

            Button("Approve", systemImage: "checkmark") {
                client.shouldPresentVerificationSheet = true
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
                client.shouldPresentVerificationSheet = true
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
                client.shouldPresentVerificationSheet = true
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
    VStack {
        Spacer()
        SessionVerificationBanner()
    }
    .environment(PreviewFixtures.incomingVerificationClient)
    .frame(width: 280, height: 200)
}

#Preview("Incoming Request (Compact)") {
    VStack {
        Spacer()
        SessionVerificationBanner()
    }
    .environment(PreviewFixtures.incomingVerificationClient)
    .frame(width: 116, height: 200)
}

#Preview("Unverified") {
    VStack {
        Spacer()
        SessionVerificationBanner()
    }
    .environment(PreviewFixtures.unverifiedClient)
    .frame(width: 280, height: 200)
}

#Preview("Unverified (Compact)") {
    VStack {
        Spacer()
        SessionVerificationBanner()
    }
    .environment(PreviewFixtures.unverifiedClient)
    .frame(width: 116, height: 200)
}

#Preview("Verified") {
    SessionVerificationBanner()
        .environment(RelayClient())
        .frame(width: 280, height: 200)
}
