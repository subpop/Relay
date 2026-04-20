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

// MARK: - Media Auto-Reveal Environment

private struct MediaAutoRevealKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Controls whether media attachments in messages are shown immediately or hidden behind a tap-to-reveal overlay.
    var mediaAutoReveal: Bool {
        get { self[MediaAutoRevealKey.self] }
        set { self[MediaAutoRevealKey.self] = newValue }
    }
}
