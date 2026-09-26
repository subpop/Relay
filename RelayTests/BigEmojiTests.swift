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

import MatrixKit
import Testing

@testable import Relay

/// Big-emoji eligibility for timeline text messages.
///
/// Markdown sends always carry `formatted_body` (e.g. `👋` arrives as
/// `<p>👋</p>`), so eligibility must consider the formatted body's visible
/// text rather than requiring its absence.
@Suite
struct BigEmojiTests {

    @Test func plainEmojiWithoutFormattedBody() {
        #expect(isBigEmojiMessage(body: "👋", formattedBody: nil))
    }

    @Test func emojiWithParagraphWrappedFormattedBody() {
        #expect(isBigEmojiMessage(body: "👋", formattedBody: "<p>👋</p>"))
    }

    @Test func multipleEmojiWithFormattedBody() {
        #expect(isBigEmojiMessage(body: "❤️🔥🎉", formattedBody: "<p>❤️🔥🎉</p>"))
    }

    @Test func upToEightEmojiQualifies() {
        let body = "😀😀😀😀😀😀😀😀"
        #expect(isBigEmojiMessage(body: body, formattedBody: "<p>\(body)</p>"))
    }

    @Test func moreThanEightEmojiDoesNotQualify() {
        let body = "😀😀😀😀😀😀😀😀😀"
        #expect(!isBigEmojiMessage(body: body, formattedBody: nil))
        #expect(!isBigEmojiMessage(body: body, formattedBody: "<p>\(body)</p>"))
    }

    @Test func mixedTextDoesNotQualify() {
        #expect(!isBigEmojiMessage(body: "Hello 👋", formattedBody: nil))
        #expect(!isBigEmojiMessage(body: "Hello 👋", formattedBody: "<p>Hello 👋</p>"))
    }

    @Test func markdownSyntaxInBodyDoesNotQualify() {
        #expect(!isBigEmojiMessage(body: "**👋**", formattedBody: nil))
    }

    @Test func formattedBodyWithExtraTextDoesNotQualify() {
        #expect(!isBigEmojiMessage(body: "👋", formattedBody: "<p>👋 hello</p>"))
    }

    @Test func quotedEmojiDoesNotQualify() {
        #expect(!isBigEmojiMessage(
            body: "👋",
            formattedBody: "<blockquote><p>👋</p></blockquote>"))
    }

    @Test func emptyBodiesDoNotQualify() {
        #expect(!isBigEmojiMessage(body: "", formattedBody: nil))
        #expect(!isBigEmojiMessage(body: "   ", formattedBody: nil))
        #expect(!isBigEmojiMessage(body: "👋", formattedBody: ""))
    }

    @Test func markdownSendAttachesFormattedBodyToEmoji() {
        // Documents the wire shape that caused the regression: even a
        // plain emoji body sent via MatrixKit carries formatted_body.
        #expect(MessageContent.markdown("👋").formattedBody != nil)
    }
}
