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

/// Matrix carries no separate caption field: a media body that differs
/// from the original filename is the sender's caption text.
@Suite @MainActor
struct MediaCaptionTests {

    private func event(
        kind: MessageKind, filename: String? = nil
    ) -> ObservableTimelineEvent {
        ObservableTimelineEvent(
            eventId: EventId(unchecked: "$caption-test"),
            sender: UserId(unchecked: "@alice:matrix.org"),
            timestamp: .now,
            kind: kind,
            filename: filename
        )
    }

    @Test func bodyMatchingFilenameIsNotACaption() {
        let event = event(
            kind: .image(body: "photo.jpg", url: "mxc://x/y", info: nil),
            filename: "photo.jpg"
        )
        #expect(event.caption == nil)
    }

    @Test func bodyDifferingFromFilenameIsACaption() {
        let event = event(
            kind: .image(body: "Sunset over the lake", url: "mxc://x/y", info: nil),
            filename: "photo.jpg"
        )
        #expect(event.caption == "Sunset over the lake")
    }

    @Test func captionRequiresAFilename() {
        let event = event(
            kind: .video(body: "clip.mp4", url: "mxc://x/y", info: nil)
        )
        #expect(event.caption == nil)
    }

    @Test func nonMediaKindsHaveNoCaption() {
        #expect(event(kind: .text(body: "hello")).caption == nil)
        #expect(event(kind: .redacted).caption == nil)
        #expect(event(kind: .unableToDecrypt).caption == nil)
    }
}
