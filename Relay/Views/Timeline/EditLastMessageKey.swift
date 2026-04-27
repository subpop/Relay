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

// MARK: - Edit Last Message Focused Value

/// A focused value key that exposes a closure to edit the current user's
/// most recent text message.  When the timeline view is focused, the
/// closure is non-nil and can be invoked from a menu command (⌘E).
struct EditLastMessageKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    /// A closure that starts editing the current user's most recent text
    /// message in the focused timeline, or `nil` when no editable message
    /// exists.
    var editLastMessage: (() -> Void)? {
        get { self[EditLastMessageKey.self] }
        set { self[EditLastMessageKey.self] = newValue }
    }
}
