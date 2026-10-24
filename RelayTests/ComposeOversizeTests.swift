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

/// Size checks that decide when the compose bar offers an alternative to
/// sending a message or file directly.
@Suite @MainActor
struct ComposeOversizeTests {

    @Test func shortTextIsWithinLimit() {
        #expect(!ComposeViewModel.exceedsEventSizeLimit("hello"))
    }

    @Test func longTextExceedsLimit() {
        let text = String(repeating: "a", count: 50_000)
        #expect(ComposeViewModel.exceedsEventSizeLimit(text))
    }

    @Test func markdownExpansionCountsTowardLimit() {
        // Plain body is under the limit, but the generated HTML body
        // roughly doubles the event content.
        let text = String(repeating: "**a** ", count: 4_000)
        #expect(text.utf8.count < ComposeViewModel.maxEventContentSize)
        #expect(ComposeViewModel.exceedsEventSizeLimit(text))
    }

    private func attachment(size: Int) throws -> StagedAttachment {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).bin")
        try Data(count: size).write(to: url)
        return StagedAttachment(url: url, filename: url.lastPathComponent, thumbnail: nil)
    }

    @Test func attachmentIsOversizedOnlyAboveLimit() throws {
        let compose = ComposeViewModel()
        let file = try attachment(size: 2_000)
        compose.maxUploadSize = 1_000
        #expect(compose.isOversized(file))
        compose.maxUploadSize = 2_000
        #expect(!compose.isOversized(file))
    }

    @Test func rejectedUploadSetsTheLimitBelowItsSize() {
        let client = RelayClient()
        #expect(client.uploadSizeLimit == nil)
        client.noteUploadTooLarge(size: 1_000)
        #expect(client.uploadSizeLimit == 999)
    }

    @Test func learnedLimitOnlyShrinks() {
        let client = RelayClient()
        client.noteUploadTooLarge(size: 1_000)
        client.noteUploadTooLarge(size: 5_000)
        #expect(client.uploadSizeLimit == 999)
        client.noteUploadTooLarge(size: 500)
        #expect(client.uploadSizeLimit == 499)
    }

    @Test func unknownLimitNeverFlagsAttachments() throws {
        let compose = ComposeViewModel()
        compose.maxUploadSize = nil
        #expect(!compose.isOversized(try attachment(size: 2_000)))
    }
}
