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

/// A banner shown at the bottom of the sidebar while a background
/// key-backup restore runs, matching the style of
/// ``SessionVerificationBanner``.
///
/// Each running restore shows its title, a determinate bar once the
/// total is known (indeterminate otherwise), and a Cancel button when
/// the restore is user-cancellable. Supports both regular and compact
/// sidebar widths.
struct KeyRestoreBanner: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.hasSpaceRail) private var hasSpaceRail
    @State private var bannerWidth: CGFloat = 0

    /// Width threshold below which the banner switches to compact layout.
    private static let compactThreshold: CGFloat = 140

    /// Whether the banner should display in compact mode.
    private var isCompact: Bool {
        let effectiveWidth = hasSpaceRail ? bannerWidth : bannerWidth - SpaceRail.width
        return effectiveWidth < Self.compactThreshold
    }

    var body: some View {
        if !client.keyFetch.tasks.isEmpty {
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
                    .fill(Color.blue.opacity(0.12))
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(client.keyFetch.tasks) { task in
                taskRow(task)
            }
        }
    }

    private func taskRow(_ task: KeyFetchTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .font(.body)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if let fraction = task.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                if let completed = task.completed, let total = task.total {
                    Text("\(completed) of \(total) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if task.task != nil {
                Button("Cancel") {
                    client.keyFetch.cancel(id: task.id)
                }
                .controlSize(.small)
            }
        }
    }

    private var compactContent: some View {
        VStack(spacing: 6) {
            ForEach(client.keyFetch.tasks) { task in
                Group {
                    if let fraction = task.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.circular)
                .controlSize(.small)

                Text(task.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if task.task != nil {
                    Button("Cancel") {
                        client.keyFetch.cancel(id: task.id)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Restoring") {
    VStack {
        Spacer()
        KeyRestoreBanner()
    }
    .environment(PreviewFixtures.restoringClient)
    .frame(width: 280, height: 200)
}

#Preview("Restoring (Indeterminate)") {
    VStack {
        Spacer()
        KeyRestoreBanner()
    }
    .environment(PreviewFixtures.restoringIndeterminateClient)
    .frame(width: 280, height: 200)
}

#Preview("Restoring (Compact)") {
    VStack {
        Spacer()
        KeyRestoreBanner()
    }
    .environment(PreviewFixtures.restoringClient)
    .frame(width: 116, height: 200)
}

#Preview("Idle") {
    VStack {
        Spacer()
        KeyRestoreBanner()
    }
    .environment(RelayClient())
    .frame(width: 280, height: 200)
}
