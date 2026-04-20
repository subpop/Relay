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

// MARK: - Mention Model

/// A resolved user mention embedded in the compose text.
///
/// Each ``Mention`` tracks the Matrix user ID, the visible display name, and the
/// range within the `NSTextView`'s attributed string where the pill is rendered.
struct Mention: Identifiable, Equatable {
    let id = UUID()
    let userId: String
    let displayName: String
    /// The character range of this mention pill in the attributed string.
    var range: NSRange
}

// MARK: - Custom Attribute Key

extension NSAttributedString.Key {
    /// Custom attribute key attached to mention pill spans, storing the Matrix user ID.
    static let mentionUserId = NSAttributedString.Key("relay.mentionUserId")
}
