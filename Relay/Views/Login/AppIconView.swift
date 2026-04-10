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

/// Displays the application icon using AppKit's `NSImageView`.
struct AppIconView: NSViewRepresentable {
    let size: CGFloat

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = NSImage(named: NSImage.applicationIconName)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentHuggingPriority(.required, for: .vertical)
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {}
}
