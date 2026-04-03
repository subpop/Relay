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

extension Character {
    /// Whether this character is an emoji (including multi-scalar sequences like flags and skin tones).
    var isEmoji: Bool {
        guard let firstScalar = unicodeScalars.first else { return false }
        // Emoji presentation sequences or characters with explicit emoji presentation.
        if firstScalar.properties.isEmoji && firstScalar.properties.isEmojiPresentation {
            return true
        }
        // Characters that become emoji when followed by a variation selector (e.g. ©️, ®️, digit keycaps).
        if firstScalar.properties.isEmoji, unicodeScalars.count > 1 {
            return true
        }
        return false
    }
}

extension String {
    /// Whether this string contains only emoji characters (ignoring whitespace).
    /// Returns `false` for empty or whitespace-only strings.
    var isEmojiOnly: Bool {
        let stripped = filter { !$0.isWhitespace }
        guard !stripped.isEmpty else { return false }
        return stripped.allSatisfy(\.isEmoji)
    }

    /// The number of emoji characters in the string (ignoring whitespace).
    var emojiCount: Int {
        filter { !$0.isWhitespace }.filter(\.isEmoji).count
    }
}
