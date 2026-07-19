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

import Testing

@testable import Relay

// MARK: - ParseCacheTests

struct ParseCacheTests {

    @Test func valueComputesAndCachesOnMiss() {
        let cache = ParseCache<String, Int>(capacity: 4)
        var computeCount = 0
        let first = cache.value(forKey: "a") { computeCount += 1; return 1 }
        let second = cache.value(forKey: "a") { computeCount += 1; return 2 }
        #expect(first == 1)
        #expect(second == 1, "A cache hit must return the originally-computed value, not recompute.")
        #expect(computeCount == 1)
    }

    @Test func peekReturnsNilOnMissWithoutComputing() {
        let cache = ParseCache<String, Int>(capacity: 4)
        #expect(cache.peek("missing") == nil)
        // A peek must not have inserted anything a subsequent `set` would collide with.
        #expect(cache.peek("missing") == nil)
    }

    @Test func peekDoesNotPromoteRecency() {
        // Fill to capacity, then peek the oldest key repeatedly — peek must not
        // count as a "use" for eviction purposes, unlike `value(forKey:compute:)`.
        let cache = ParseCache<String, Int>(capacity: 2)
        cache.set(1, forKey: "oldest")
        cache.set(2, forKey: "newer")
        for _ in 0 ..< 5 { _ = cache.peek("oldest") }
        cache.set(3, forKey: "evictor")
        #expect(cache.peek("oldest") == nil, "peek() must not promote recency; 'oldest' should still be evicted.")
        #expect(cache.peek("newer") == 2)
        #expect(cache.peek("evictor") == 3)
    }

    @Test func setEvictsLeastRecentlyUsedPastCapacity() {
        let cache = ParseCache<Int, String>(capacity: 3)
        cache.set("a", forKey: 1)
        cache.set("b", forKey: 2)
        cache.set("c", forKey: 3)
        cache.set("d", forKey: 4) // Evicts 1 (least recently touched).
        #expect(cache.peek(1) == nil)
        #expect(cache.peek(2) == "b")
        #expect(cache.peek(3) == "c")
        #expect(cache.peek(4) == "d")
    }

    @Test func setOnExistingKeyRefreshesRecencyAndDoesNotGrow() {
        let cache = ParseCache<Int, String>(capacity: 3)
        cache.set("a", forKey: 1)
        cache.set("b", forKey: 2)
        cache.set("c", forKey: 3)
        // Touch key 1 so it's most-recently-used; key 2 becomes the LRU entry.
        cache.set("a-updated", forKey: 1)
        cache.set("d", forKey: 4) // Should evict 2, not 1.
        #expect(cache.peek(1) == "a-updated", "Re-setting an existing key must update its value.")
        #expect(cache.peek(2) == nil, "Key 2 was least-recently-used after key 1 was refreshed.")
        #expect(cache.peek(3) == "c")
        #expect(cache.peek(4) == "d")
    }

    @Test func valueForKeyPromotesRecencyOnHit() {
        let cache = ParseCache<Int, String>(capacity: 3)
        cache.set("a", forKey: 1)
        cache.set("b", forKey: 2)
        cache.set("c", forKey: 3)
        // Reading key 1 via value(forKey:) should count as a use, sparing it
        // from eviction in favor of key 2 (now the LRU entry).
        _ = cache.value(forKey: 1) { "unused" }
        cache.set("d", forKey: 4)
        #expect(cache.peek(1) == "a")
        #expect(cache.peek(2) == nil)
    }

    @Test func removeAllEmptiesCacheAndRecency() {
        let cache = ParseCache<Int, String>(capacity: 2)
        cache.set("a", forKey: 1)
        cache.set("b", forKey: 2)
        cache.removeAll()
        #expect(cache.peek(1) == nil)
        #expect(cache.peek(2) == nil)
        // Recency bookkeeping must also be reset — three fresh inserts after a
        // clear on a capacity-2 cache should evict the first of the three, not
        // silently mis-evict based on stale pre-clear order entries.
        cache.set("x", forKey: 10)
        cache.set("y", forKey: 11)
        cache.set("z", forKey: 12)
        #expect(cache.peek(10) == nil)
        #expect(cache.peek(11) == "y")
        #expect(cache.peek(12) == "z")
    }

    @Test func evictionUnderSustainedPressureKeepsOnlyMostRecentCapacityEntries() {
        let capacity = 8
        let cache = ParseCache<Int, Int>(capacity: capacity)
        for key in 0 ..< 256 {
            cache.set(key, forKey: key)
        }
        for key in 0 ..< (256 - capacity) {
            #expect(cache.peek(key) == nil, "Key \(key) should have been evicted long before the cache filled 256 entries at capacity \(capacity).")
        }
        for key in (256 - capacity) ..< 256 {
            #expect(cache.peek(key) == key, "The most recent \(capacity) entries must all survive.")
        }
    }
}
