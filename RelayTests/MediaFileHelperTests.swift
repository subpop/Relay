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
import Testing

@testable import Relay

struct MediaFileHelperTests {
    @Test func thumbnailFileIsDistinctPNGThatDecodesAsImage() throws {
        let download = MediaFileHelper.Download(
            mxcURL: "mxc://example.org/thumbnail-fallback-test",
            filename: "Screenshot.png"
        )
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }

        let url = try MediaFileHelper.writeThumbnailToTemporaryFile(image, for: download)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent.hasSuffix("-thumbnail.png"))
        #expect(url != MediaFileHelper.temporaryFileURL(for: download))
        #expect(NSImage(contentsOf: url) != nil)
    }
}
