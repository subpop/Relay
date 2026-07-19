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
/// content is re-parsed on every SwiftUI body evaluation. Backed by a
/// dictionary of doubly-linked-list nodes so every operation (get, set,
/// recency promotion, eviction) is O(1) rather than scanning a recency array.
final class ParseCache<Key: Hashable, Value>: @unchecked Sendable {
    /// `prev` is `weak` so the list's only strong ownership chain runs
    /// `head -> next -> ... -> tail`; dropping a node from `nodes` and
    /// unlinking it from that chain lets ARC deallocate it immediately,
    /// instead of the two directions retaining each other forever.
    private final class Node {
        let key: Key
        var value: Value
        weak var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private let capacity: Int
    private var nodes: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Returns the cached value for `key`, or computes and caches it using `compute`.
    func value(forKey key: Key, compute: () -> Value) -> Value {
        lock.lock()
        if let node = nodes[key] {
            moveToFront(node)
            let cached = node.value
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = compute()

        lock.lock()
        defer { lock.unlock() }
        // A concurrent caller may have inserted this key while `compute()`
        // ran unlocked; keep the existing value (first writer wins) rather
        // than inserting a second node for the same key.
        if let existing = nodes[key] {
            moveToFront(existing)
            return existing.value
        }
        insert(key: key, value: result)
        return result
    }

    /// Returns the cached value for `key` without computing or promoting it —
    /// an O(1) read safe to call from hot paths such as SwiftUI `body`. Recency
    /// is updated only by ``set(_:forKey:)``, which suffices for caches that
    /// write on resolution. Returns `nil` on a miss.
    func peek(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[key]?.value
    }

    /// Removes every cached entry. Used when a global input the cached values
    /// depend on (e.g. the message text-zoom level) changes and every previously
    /// computed value is stale.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        nodes.removeAll()
        head = nil
        tail = nil
    }

    /// Stores `value` for `key`, evicting the least-recently-used entry when the
    /// cache exceeds its capacity.
    func set(_ value: Value, forKey key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if let node = nodes[key] {
            node.value = value
            moveToFront(node)
        } else {
            insert(key: key, value: value)
        }
    }

    // MARK: - Linked-list bookkeeping (call only while holding `lock`)

    private func insert(key: Key, value: Value) {
        let node = Node(key: key, value: value)
        nodes[key] = node
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
        evictIfNeeded()
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func evictIfNeeded() {
        while nodes.count > capacity, let evicted = tail {
            nodes.removeValue(forKey: evicted.key)
            tail = evicted.prev
            tail?.next = nil
            if head === evicted { head = nil }
        }
    }
}
