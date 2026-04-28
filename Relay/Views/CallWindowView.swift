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
import RelayInterface
import SwiftUI

/// Shared call state accessible from both ``MainView`` (to start calls) and
/// ``CallWindowView`` (to display the call UI in its own window).
@Observable
@MainActor
final class CallManager {
    var activeCallViewModel: (any CallViewModelProtocol)?
    var isPreparingCredentials: Bool = false
    var callRoomId: String?

    /// Whether there is an active or preparing call.
    var hasActiveCall: Bool {
        activeCallViewModel != nil
    }

    func endCall() async {
        await activeCallViewModel?.disconnect()
        // Defer observable state teardown to the next run-loop iteration.
        // Setting activeCallViewModel = nil swaps the entire CallWindowView
        // body (CallView → Color.black). If that fires during an active
        // AppKit layout pass it triggers a recursive constraint update crash
        // on the main window.
        DispatchQueue.main.async { [self] in
            activeCallViewModel = nil
            isPreparingCredentials = false
            callRoomId = nil
        }
    }
}

// MARK: - Environment Key

private struct CallManagerKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = CallManager()
}

extension EnvironmentValues {
    var callManager: CallManager {
        get { self[CallManagerKey.self] }
        set { self[CallManagerKey.self] = newValue }
    }
}

/// Hosts the ``CallView`` inside the dedicated call window.
///
/// This view reads the shared ``CallManager`` from the environment and
/// presents the call UI. When the call ends or is dismissed, it closes
/// the window via `dismissWindow`.
struct CallWindowView: View {
    @Environment(\.callManager) private var callManager
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let viewModel = callManager.activeCallViewModel {
                CallView(
                    viewModel: viewModel,
                    isPreparingCredentials: callManager.isPreparingCredentials
                ) {
                    // Only tear down state — the onChange handler below is the
                    // single dismiss path once hasActiveCall becomes false.
                    Task { await callManager.endCall() }
                }
            } else {
                // No active call — show placeholder until the window closes.
                Color.black
            }
        }
        .ignoresSafeArea()
        .background(WindowStyler())
        .onChange(of: callManager.hasActiveCall) { _, hasCall in
            if !hasCall {
                DispatchQueue.main.async {
                    dismissWindow(id: "call")
                }
            }
        }
    }
}

// MARK: - Window Styler

/// Configures the call window to have a fully transparent title bar with
/// content extending underneath it, while keeping the `.hiddenTitleBar`
/// window style for drag, resize, and window management support.
private struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StylerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class StylerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            // Hide the traffic light buttons.
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
