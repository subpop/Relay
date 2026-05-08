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

/// A compact banner shown at the bottom of the sidebar when the device
/// is offline, matching the style of ``SessionVerificationBanner``.
///
/// Automatically appears when ``SyncState`` is `.offline` and disappears
/// when connectivity is restored. Supports both regular and compact
/// sidebar widths.
struct OfflineBanner: View {
    @Environment(\.matrixService) private var matrixService
    @State private var bannerWidth: CGFloat = 0

    /// Width threshold below which the banner switches to compact layout.
    private static let compactThreshold: CGFloat = 180

    private var isCompact: Bool {
        bannerWidth < Self.compactThreshold
    }

    /// When the radio is off (`NWPathMonitor` reports no path) we say
    /// "Network Offline" and use the wifi-slash glyph. When the radio
    /// is up but the homeserver isn't responding we say "Server
    /// Offline" with a server-shaped glyph. Both share the same banner
    /// chrome and the same orange tint — only the copy/icon differs.
    private var isNetworkOffline: Bool {
        !matrixService.isNetworkConnected
    }

    private var titleText: String {
        isNetworkOffline ? "Network Offline" : "Server Unreachable"
    }

    /// Status icon. For "Network Offline" we use the standard
    /// `wifi.slash` SF Symbol. For "Server Offline" SF Symbols doesn't
    /// ship a slashed-server glyph, so we pair `xserve` with a
    /// caution-triangle badge — same pattern as
    /// ``foo.badge.exclamationmark`` symbols Apple uses elsewhere.
    @ViewBuilder
    private func statusIcon(size: CGFloat) -> some View {
        if isNetworkOffline {
            Image(systemName: "wifi.slash")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "xserve")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: size * 0.55))
                        .foregroundStyle(.orange)
                        .offset(x: size * 0.22, y: size * 0.18)
                }
        }
    }

    var body: some View {
        if matrixService.syncState == .offline {
            Group {
                if isCompact {
                    compactContent
                } else {
                    regularContent
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isCompact ? 12 : 8)
            .frame(maxWidth: .infinity)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var regularContent: some View {
        HStack(spacing: 8) {
            statusIcon(size: 17)

            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Spacer(minLength: 4)
        }
    }

    private var compactContent: some View {
        VStack(spacing: 6) {
            statusIcon(size: 24)

            Text(titleText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("Network Offline") {
    VStack {
        Spacer()
        OfflineBanner()
    }
    .environment(\.matrixService, {
        let service = PreviewMatrixService()
        service.syncState = .offline
        service.isNetworkConnected = false
        return service
    }())
    .frame(width: 280, height: 200)
}

#Preview("Server Unreachable") {
    VStack {
        Spacer()
        OfflineBanner()
    }
    .environment(\.matrixService, {
        let service = PreviewMatrixService()
        service.syncState = .offline
        service.isNetworkConnected = true
        return service
    }())
    .frame(width: 280, height: 200)
}

#Preview("Network Offline (Compact)") {
    VStack {
        Spacer()
        OfflineBanner()
    }
    .environment(\.matrixService, {
        let service = PreviewMatrixService()
        service.syncState = .offline
        service.isNetworkConnected = false
        return service
    }())
    .frame(width: 116, height: 200)
}

#Preview("Online") {
    VStack {
        Spacer()
        OfflineBanner()
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 280, height: 200)
}
