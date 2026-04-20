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
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 1) {
                Text("Offline")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Spacer(minLength: 4)
        }
    }

    private var compactContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.system(size: 24))

            Text("Offline")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("Offline") {
    VStack {
        Spacer()
        OfflineBanner()
    }
    .environment(\.matrixService, {
        let service = PreviewMatrixService()
        service.syncState = .offline
        return service
    }())
    .frame(width: 280, height: 200)
}

#Preview("Offline (Compact)") {
    VStack {
        Spacer()
        OfflineBanner()
    }
    .environment(\.matrixService, {
        let service = PreviewMatrixService()
        service.syncState = .offline
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
