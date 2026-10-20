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

struct LinkPreviewSkipListTests {
    @Test func excludedDomainsKeepURLAvailableForTitlePreview() {
        let defaults = UserDefaults.standard
        let oldDomains = defaults.object(forKey: LinkPreviewSkipList.storageKey)
        let oldRevision = defaults.object(forKey: LinkPreviewSkipList.revisionKey)
        defer {
            if let oldDomains {
                defaults.set(oldDomains, forKey: LinkPreviewSkipList.storageKey)
            } else {
                defaults.removeObject(forKey: LinkPreviewSkipList.storageKey)
            }
            if let oldRevision {
                defaults.set(oldRevision, forKey: LinkPreviewSkipList.revisionKey)
            } else {
                defaults.removeObject(forKey: LinkPreviewSkipList.revisionKey)
            }
        }

        LinkPreviewSkipList.setDomains([" YouTube.com ", "YOUTUBE.COM", ""])

        #expect(LinkPreviewSkipList.domains() == ["youtube.com"])
        #expect(URL(string: "https://www.youtube.com/watch?v=abc").map {
            LinkPreviewSkipList.excludesThumbnail(for: $0)
        } == true)
        #expect(URL(string: "https://notyoutube.com/watch?v=abc").map {
            LinkPreviewSkipList.excludesThumbnail(for: $0)
        } == false)

        let message = "See https://www.youtube.com/watch?v=abc \(UUID())"
        #expect(URLPreviewExtractor.firstPreviewURL(in: message)?.host == "www.youtube.com")
    }
}
