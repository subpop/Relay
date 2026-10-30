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
import os

private let logger = Logger(subsystem: "app.subpop.Relay", category: "ShieldResizeGuard")

/// Restores a window's frame after macOS shrinks it for the Downtime shield.
///
/// When Downtime turns on, the system resizes a blocked app's windows to the
/// shield's fixed size, below the window's own `minSize`. AppKit then clamps
/// the window to its minimum once it is hidden, and nothing restores the
/// original frame when Downtime ends. A window can't be sized below `minSize`
/// by the user, so such a resize identifies the shield; the guard remembers
/// the last frame from before it and reapplies it when the window is visible
/// again.
final class ShieldResizeGuard {
    private var lastFrames: [ObjectIdentifier: NSRect] = [:]
    private var shrunkWindows: Set<ObjectIdentifier> = []

    /// Tracks a window resize, flagging resizes below the window's minimum size.
    func windowDidResize(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            shrunkWindows.insert(id)
        } else if !shrunkWindows.contains(id) {
            lastFrames[id] = window.frame
        }
    }

    /// Restores a flagged window's frame once it is visible and back at or
    /// above its minimum size, which is when the system has finished with it.
    func windowDidChangeOcclusionState(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard shrunkWindows.contains(id), window.occlusionState.contains(.visible),
            window.frame.width >= window.minSize.width, window.frame.height >= window.minSize.height
        else { return }
        shrunkWindows.remove(id)
        guard let frame = lastFrames[id] else { return }
        logger.info("Restoring window frame \(NSStringFromRect(frame), privacy: .public) after shield resize")
        window.setFrame(frame, display: true)
    }
}
