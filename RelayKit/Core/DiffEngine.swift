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

// DiffEngine.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// Applies VectorDiff-style update operations to a Swift array.
///
/// The Matrix SDK delivers state changes as a sequence of diff operations
/// (append, clear, insert, set, remove, pushFront, pushBack, popFront,
/// popBack, truncate, reset). `DiffEngine` applies these operations
/// to maintain a local Swift array that mirrors the SDK's internal state.
///
/// Used by both ``RoomSummaryProvider`` (for `RoomListEntriesUpdate`)
/// and ``TimelineItemProvider`` (for `TimelineDiff`).
///
/// ## Usage
///
/// ```swift
/// var items: [String] = []
/// let operation = DiffOperation<String>.append(["a", "b", "c"])
/// items = DiffEngine.apply(operation, to: items)
/// // items == ["a", "b", "c"]
/// ```
///
/// ## Topics
///
/// ### Applying Operations
/// - ``apply(_:to:)``
/// - ``applyBatch(_:to:)``
///
/// ### Operations
/// - ``DiffOperation``
public enum DiffEngine {
    // swiftlint:disable cyclomatic_complexity
    /// Applies a single diff operation to an array, returning the updated array.
    ///
    /// - Parameters:
    ///   - operation: The diff operation to apply.
    ///   - items: The current array of items.
    /// - Returns: The array after applying the operation.
    public static func apply<Element>(_ operation: DiffOperation<Element>, to items: [Element]) -> [Element] {
    // swiftlint:enable cyclomatic_complexity
        var result = items
        switch operation {
        case .append(let newItems):
            result.append(contentsOf: newItems)
        case .clear:
            result.removeAll()
        case .pushFront(let item):
            result.insert(item, at: 0)
        case .pushBack(let item):
            result.append(item)
        case .popFront:
            if !result.isEmpty {
                result.removeFirst()
            }
        case .popBack:
            if !result.isEmpty {
                result.removeLast()
            }
        case .insert(let index, let item):
            result.insert(item, at: index)
        case .set(let index, let item):
            result[index] = item
        case .remove(let index):
            result.remove(at: index)
        case .truncate(let length):
            if length < result.count {
                result = Array(result.prefix(length))
            }
        case .reset(let newItems):
            result = newItems
        }
        return result
    }

    /// Applies a batch of diff operations to an array in order,
    /// returning the final updated array.
    ///
    /// - Parameters:
    ///   - operations: The sequence of diff operations to apply.
    ///   - items: The current array of items.
    /// - Returns: The array after applying all operations.
    public static func applyBatch<Element>(_ operations: [DiffOperation<Element>], to items: [Element]) -> [Element] {
        operations.reduce(items) { current, operation in
            apply(operation, to: current)
        }
    }
}

/// A diff operation that can be applied to an array.
///
/// Mirrors the VectorDiff semantics used by the Matrix SDK for both
/// timeline items and room list entries.
///
/// ## Topics
///
/// ### Adding Items
/// - ``append(_:)``
/// - ``pushFront(_:)``
/// - ``pushBack(_:)``
/// - ``insert(_:_:)``
///
/// ### Modifying Items
/// - ``set(_:_:)``
///
/// ### Removing Items
/// - ``popFront``
/// - ``popBack``
/// - ``remove(_:)``
/// - ``clear``
/// - ``truncate(_:)``
///
/// ### Replacing All Items
/// - ``reset(_:)``
public enum DiffOperation<Element> {
    /// Appends one or more items to the end of the array.
    ///
    /// - Parameter items: The items to append.
    case append([Element])

    /// Removes all items from the array.
    case clear

    /// Inserts an item at the beginning of the array.
    ///
    /// - Parameter item: The item to insert.
    case pushFront(Element)

    /// Appends a single item to the end of the array.
    ///
    /// - Parameter item: The item to append.
    case pushBack(Element)

    /// Removes the first item from the array.
    case popFront

    /// Removes the last item from the array.
    case popBack

    /// Inserts an item at the specified index.
    ///
    /// - Parameters:
    ///   - index: The position at which to insert the item.
    ///   - item: The item to insert.
    case insert(Int, Element)

    /// Replaces the item at the specified index.
    ///
    /// - Parameters:
    ///   - index: The position of the item to replace.
    ///   - item: The replacement item.
    case set(Int, Element)

    /// Removes the item at the specified index.
    ///
    /// - Parameter index: The position of the item to remove.
    case remove(Int)

    /// Truncates the array to the specified length.
    ///
    /// Items beyond the given length are removed.
    ///
    /// - Parameter length: The maximum number of items to retain.
    case truncate(Int)

    /// Replaces the entire array with new items.
    ///
    /// - Parameter items: The new items.
    case reset([Element])
}
