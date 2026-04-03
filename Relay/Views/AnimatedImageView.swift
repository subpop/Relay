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
import SwiftUI

/// A SwiftUI wrapper around `NSImageView` that plays animated GIF frames.
///
/// Standard SwiftUI `Image` renders only the first frame of a multi-frame GIF.
/// This view uses AppKit's `NSImageView` with `animates = true` to display the
/// full animation. When `isAnimating` is `false`, only the first frame is shown.
///
/// Use ``AnimatedImageView/init(data:isAnimating:)`` for local data, or
/// ``AnimatedImageView/init(url:isAnimating:)`` for remote URLs.
struct AnimatedImageView: NSViewRepresentable {
    /// The raw image data (GIF, PNG, JPEG, etc.).
    let data: Data?

    /// Whether the animation should play. When `false`, shows the first frame.
    let isAnimating: Bool

    init(data: Data?, isAnimating: Bool = true) {
        self.data = data
        self.isAnimating = isAnimating
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.wantsLayer = true
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        if let data {
            let image = NSImage(data: data)
            imageView.image = image
        } else {
            imageView.image = nil
        }
        imageView.animates = isAnimating
    }
}

/// An animated image view that asynchronously loads its data from a URL.
///
/// Shows a progress indicator while loading, then displays the animated image.
/// Falls back to a static placeholder on failure.
struct AsyncAnimatedImageView: View {
    let url: URL
    let isAnimating: Bool

    @State private var data: Data?
    @State private var isLoading = true
    @State private var hasFailed = false

    var body: some View {
        ZStack {
            if let data {
                AnimatedImageView(data: data, isAnimating: isAnimating)
            } else if hasFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            isLoading = true
            hasFailed = false
            do {
                let (responseData, _) = try await URLSession.shared.data(from: url)
                data = responseData
            } catch {
                hasFailed = true
            }
            isLoading = false
        }
    }
}
