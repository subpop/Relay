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

struct MediaDiskCacheTests {
    @Test func encryptedEntriesAreKeptApartFromPlaintext() async {
        let mxc = "mxc://example.org/\(UUID().uuidString)"
        let encryptedKey = MediaDiskCache.encryptedKey(mxc)
        #expect(encryptedKey != mxc)

        let cache = MediaDiskCache.shared
        await cache.write(key: encryptedKey, data: Data("ciphertext".utf8))
        #expect(await cache.read(key: encryptedKey) == Data("ciphertext".utf8))
        #expect(await cache.read(key: mxc) == nil)
    }
}
