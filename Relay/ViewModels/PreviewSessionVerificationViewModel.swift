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

import Foundation
import RelayInterface

/// A mock implementation of ``SessionVerificationViewModelProtocol`` for use in SwiftUI previews.
///
/// Simulates the verification flow with short delays, progressing through requesting,
/// waiting, emoji comparison, and verified states.
@Observable
final class PreviewSessionVerificationViewModel: SessionVerificationViewModelProtocol {
    var state: VerificationState
    var emojis: [VerificationEmoji]

    init(state: VerificationState = .idle, emojis: [VerificationEmoji] = []) {
        self.state = state
        self.emojis = emojis
    }

    func requestVerification() async {
        state = .requesting
        try? await Task.sleep(for: .seconds(1))
        state = .waitingForOtherDevice
        try? await Task.sleep(for: .seconds(2))
        emojis = Self.sampleEmojis
        state = .showingEmojis
    }

    func approveVerification() async {
        state = .waitingForApproval
        try? await Task.sleep(for: .seconds(1))
        state = .verified
    }

    func declineVerification() async {
        state = .cancelled
    }

    func cancelVerification() async {
        state = .cancelled
    }

    /// Sample emoji data for previewing the emoji comparison step.
    static let sampleEmojis: [VerificationEmoji] = [
        .init(id: 0, symbol: "🐶", label: "Dog"),
        .init(id: 1, symbol: "🔑", label: "Key"),
        .init(id: 2, symbol: "☎️", label: "Telephone"),
        .init(id: 3, symbol: "🎩", label: "Hat"),
        .init(id: 4, symbol: "🏁", label: "Flag"),
        .init(id: 5, symbol: "🚀", label: "Rocket"),
        .init(id: 6, symbol: "🎵", label: "Music"),
    ]
}
