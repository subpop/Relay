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

/// Scroll-to-bottom button, loading more indicator, and empty/loading state overlays.
struct TimelinePaginationOverlay: View {
    let isLoading: Bool
    let isLoadingMore: Bool
    let isEmpty: Bool
    let isLive: Bool
    let isNearEnd: Bool
    let onScrollToEnd: () -> Void
    let onReturnToLive: () -> Void

    var body: some View {
        ZStack {
            loadingMoreIndicator
            scrollToBottomButton
            loadingOrEmptyState
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loadingMoreIndicator: some View {
        if isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var scrollToBottomButton: some View {
        if !isLive || !isNearEnd {
            Button {
                if !isLive {
                    onReturnToLive()
                } else {
                    onScrollToEnd()
                }
            } label: {
                Image(systemName: !isLive ? "arrow.uturn.down" : "arrow.down")
                    .font(.title)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 56)
            .padding(.trailing, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    @ViewBuilder
    private var loadingOrEmptyState: some View {
        if isLoading && isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !isLoading && isEmpty {
            ContentUnavailableView(
                "No Messages Yet",
                systemImage: "text.bubble",
                description: Text("Send a message to get the conversation started.")
            )
        }
    }
}
