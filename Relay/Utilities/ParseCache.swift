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

/// A simple LRU cache for expensive parse results (HTML, Markdown, URL detection).
///
/// Thread-safe via `NSLock`. Designed for main-thread hot paths where the same
/// content is re-parsed on every SwiftUI body evaluation.
final class ParseCache<Key: Hashable, Value>: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Returns the cached value for `key`, or computes and caches it using `compute`.
    func value(forKey key: Key, compute: () -> Value) -> Value {
        lock.lock()
        if let cached = storage[key] {
            // Move to end (most recently used).
            if let idx = order.firstIndex(of: key) {
                order.append(order.remove(at: idx))
            }
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = compute()

        lock.lock()
        storage[key] = result
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
        lock.unlock()

        return result
    }
}
