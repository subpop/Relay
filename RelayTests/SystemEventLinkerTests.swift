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
import Testing

@testable import Relay

/// Links found in an attributed string as (linked text, URL) pairs.
private func links(in attributed: AttributedString) -> [(text: String, url: URL)] {
    attributed.runs.compactMap { run in
        guard let url = run.link else { return nil }
        return (String(attributed[run.range].characters), url)
    }
}

@Suite("SystemEventLinker")
struct SystemEventLinkerTests {
    @Test("Profile change links the sender's name")
    func profileChange() {
        let result = SystemEventLinker.linkedDescription(
            "Bob updated their avatar",
            senderName: "Bob",
            senderID: "@bob:matrix.org",
            targetName: nil,
            targetID: nil
        )
        let found = links(in: result)
        #expect(found.count == 1)
        #expect(found.first?.text == "Bob")
        #expect(found.first?.url.absoluteString == "https://matrix.to/#/@bob:matrix.org")
    }

    @Test("Display-name change does not link inside the new name")
    func displayNameChange() {
        let result = SystemEventLinker.linkedDescription(
            "Alice changed their display name from “Alice” to “Alicia”",
            senderName: "Alice",
            senderID: "@alice:matrix.org",
            targetName: nil,
            targetID: nil
        )
        let found = links(in: result)
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.text == "Alice" })
        #expect(found.allSatisfy { $0.url.absoluteString == "https://matrix.to/#/@alice:matrix.org" })
    }

    @Test("Invite links the actor and the invitee")
    func invite() {
        let result = SystemEventLinker.linkedDescription(
            "Alice invited Bob",
            senderName: "Alice",
            senderID: "@alice:matrix.org",
            targetName: "Bob",
            targetID: "@bob:matrix.org"
        )
        let found = links(in: result)
        #expect(found.count == 2)
        #expect(found[0].text == "Alice")
        #expect(found[0].url.absoluteString == "https://matrix.to/#/@alice:matrix.org")
        #expect(found[1].text == "Bob")
        #expect(found[1].url.absoluteString == "https://matrix.to/#/@bob:matrix.org")
    }

    @Test("Kick links the removed user")
    func kick() {
        let result = SystemEventLinker.linkedDescription(
            "Alice removed Bob",
            senderName: "Alice",
            senderID: "@alice:matrix.org",
            targetName: "Bob",
            targetID: "@bob:matrix.org"
        )
        let found = links(in: result)
        #expect(found.count == 2)
        #expect(found[1].text == "Bob")
        #expect(found[1].url.absoluteString == "https://matrix.to/#/@bob:matrix.org")
    }

    @Test("Unknown target name falls back to the user ID in the text")
    func unknownTargetName() {
        let result = SystemEventLinker.linkedDescription(
            "Alice removed @bob:matrix.org",
            senderName: "Alice",
            senderID: "@alice:matrix.org",
            targetName: nil,
            targetID: "@bob:matrix.org"
        )
        let found = links(in: result)
        #expect(found.count == 2)
        #expect(found[1].text == "@bob:matrix.org")
        #expect(found[1].url.absoluteString == "https://matrix.to/#/@bob:matrix.org")
    }

    @Test("Identical display names anchor the actor first and the target after")
    func identicalDisplayNames() {
        let result = SystemEventLinker.linkedDescription(
            "Sam invited Sam",
            senderName: "Sam",
            senderID: "@sam:matrix.org",
            targetName: "Sam",
            targetID: "@samuel:matrix.org"
        )
        let found = links(in: result)
        #expect(found.count == 2)
        #expect(found[0].url.absoluteString == "https://matrix.to/#/@sam:matrix.org")
        #expect(found[1].url.absoluteString == "https://matrix.to/#/@samuel:matrix.org")
    }

    @Test("Unrelated text stays unlinked")
    func noMatch() {
        let result = SystemEventLinker.linkedDescription(
            "Room renamed to “General”",
            senderName: "Alice",
            senderID: "@alice:matrix.org",
            targetName: nil,
            targetID: nil
        )
        #expect(links(in: result).isEmpty)
        #expect(String(result.characters) == "Room renamed to “General”")
    }
}
