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
        activeCallViewModel = nil
        isPreparingCredentials = false
        callRoomId = nil
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
                    Task {
                        await callManager.endCall()
                        // Defer dismissal to the next run loop iteration so it
                        // doesn't fire during a SwiftUI layout pass, which causes
                        // a recursive constraint update crash.
                        DispatchQueue.main.async {
                            dismissWindow(id: "call")
                        }
                    }
                }
            } else {
                // No active call — show placeholder until the window closes.
                Color.black
            }
        }
        .onChange(of: callManager.hasActiveCall) { _, hasCall in
            if !hasCall {
                DispatchQueue.main.async {
                    dismissWindow(id: "call")
                }
            }
        }
    }
}
