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
import Testing

@testable import Relay

@Suite("BubbleStyle")
struct BubbleStyleTests {
    @Test func outgoingGreyBubbleUsesChosenColor() {
        let style = BubbleStyle.message(
            isOutgoing: true,
            senderID: "@me:matrix.org",
            coloredBubbles: false,
            outgoingColor: .red
        )
        #expect(style.backgroundColor == Color.red)
        #expect(style.usesWhiteText)
    }

    @Test func yellowOutgoingBubbleUsesDarkText() {
        let style = BubbleStyle.message(
            isOutgoing: true,
            senderID: "@me:matrix.org",
            coloredBubbles: false,
            outgoingColor: .yellow
        )
        #expect(!style.usesWhiteText)
    }

    @Test func coloredBubblesIgnoreOutgoingColor() {
        let style = BubbleStyle.message(
            isOutgoing: true,
            senderID: "@me:matrix.org",
            coloredBubbles: true,
            outgoingColor: .yellow
        )
        #expect(style.backgroundColor != Color.yellow)
        #expect(style.usesWhiteText)
    }

    @Test func incomingGreyBubbleIgnoresOutgoingColor() {
        let style = BubbleStyle.message(
            isOutgoing: false,
            senderID: "@alice:matrix.org",
            coloredBubbles: false,
            outgoingColor: .red
        )
        #expect(style.backgroundColor != Color.red)
        #expect(!style.usesWhiteText)
    }

    @Test func rawValuesAreStable() {
        // Persisted in UserDefaults; renaming a case would reset the setting.
        #expect(OutgoingBubbleColor.accent.rawValue == "accent")
        #expect(OutgoingBubbleColor.cyan.rawValue == "cyan")
    }
}
