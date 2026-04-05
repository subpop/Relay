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
import Foundation
import RelayInterface

/// A mock ``CallViewModelProtocol`` for SwiftUI previews.
///
/// Simulates a connected call with sample participants after a short delay.
/// All methods are safe to call from the main actor, and no real media or
/// network connections are established.
@Observable
@MainActor
final class PreviewCallViewModel: CallViewModelProtocol {
    var state: CallState = .idle
    var participants: [CallParticipant] = []
    var isLocalCameraEnabled: Bool = false
    var isLocalMicrophoneEnabled: Bool = false
    var localParticipantID: String? = nil
    var videoTrackRevision: UInt = 0

    func connect(url: String, token: String) async throws {
        state = .connecting
        try? await Task.sleep(for: .milliseconds(800))
        isLocalCameraEnabled = true
        isLocalMicrophoneEnabled = true
        localParticipantID = "@preview:matrix.org"
        participants = [
            CallParticipant(
                id: "@alice:matrix.org",
                displayName: "Alice Smith",
                isCameraEnabled: true,
                isMicrophoneEnabled: true,
                isSpeaking: true
            ),
            CallParticipant(
                id: "@bob:matrix.org",
                displayName: "Bob Chen",
                isCameraEnabled: false,
                isMicrophoneEnabled: true,
                isSpeaking: false
            )
        ]
        state = .connected
    }

    func disconnect() async {
        state = .disconnected
        participants = []
        isLocalCameraEnabled = false
        isLocalMicrophoneEnabled = false
        localParticipantID = nil
    }

    func toggleCamera() async throws {
        isLocalCameraEnabled.toggle()
    }

    func toggleMicrophone() async throws {
        isLocalMicrophoneEnabled.toggle()
    }

    func makeVideoView(for participantID: String) -> NSView? { nil }
}
