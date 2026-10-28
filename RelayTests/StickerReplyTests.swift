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
import MatrixKit
import Testing

@testable import Relay

/// Replying with a sticker from the picker.
@Suite
struct StickerReplyTests {
    private let image = ImagePackImage(
        url: "mxc://matrix.org/cat", body: "a waving cat",
        info: MediaInfo(mimeType: "image/png", width: 128, height: 128))

    @Test func aStickerSentWhileReplyingCarriesTheReply() {
        let content = TimelineViewModel.stickerContent(
            for: image, shortcode: "cat_wave", inReplyTo: "$parent:matrix.org")
        #expect(content.relatesTo == .reply(to: EventId(unchecked: "$parent:matrix.org")))
        #expect(content.body == "a waving cat")
        #expect(content.url == "mxc://matrix.org/cat")
    }

    @Test func aStickerSentWithoutAReplyHasNoRelation() {
        let content = TimelineViewModel.stickerContent(
            for: image, shortcode: "cat_wave", inReplyTo: nil)
        #expect(content.relatesTo == nil)
    }

    @Test func theReplyIsOnTheWireAsMRelatesTo() throws {
        let content = TimelineViewModel.stickerContent(
            for: image, shortcode: "cat_wave", inReplyTo: "$parent:matrix.org")
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
        let relation = try #require(json["m.relates_to"] as? [String: Any])
        let replyTo = try #require(relation["m.in_reply_to"] as? [String: Any])
        #expect(replyTo["event_id"] as? String == "$parent:matrix.org")
    }
}
