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

// TypeConversions.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Extensions for converting between Matrix SDK FFI types and
/// idiomatic Swift types.
///
/// These conversions are used throughout the proxy layer to present
/// SDK data in Swift-native forms:
/// - `String` URL fields become `URL?`
/// - `UInt64` millisecond timestamps become `Date`

// MARK: - URL Conversions

extension String {
    /// Converts a Matrix MXC URI or URL string to a `URL`.
    ///
    /// Returns `nil` if the string is empty or not a valid URL.
    ///
    /// - Returns: A `URL` if the string is a valid URL, otherwise `nil`.
    public var matrixURL: URL? {
        guard !isEmpty else { return nil }
        return URL(string: self)
    }
}

extension Optional<String> {
    /// Converts an optional URL string to a `URL`.
    ///
    /// Returns `nil` if the string is `nil`, empty, or not a valid URL.
    ///
    /// - Returns: A `URL` if the string is a valid URL, otherwise `nil`.
    public var matrixURL: URL? {
        self?.matrixURL
    }
}

// MARK: - Timestamp Conversions

extension UInt64 {
    /// Converts a millisecond timestamp to a `Date`.
    ///
    /// The Matrix SDK uses millisecond Unix timestamps. This property
    /// converts them to Swift `Date` values.
    ///
    /// - Returns: A `Date` representing the timestamp.
    public var matrixDate: Date {
        Date(timeIntervalSince1970: TimeInterval(self) / 1000.0)
    }
}

extension Optional<UInt64> {
    /// Converts an optional millisecond timestamp to a `Date`.
    ///
    /// Returns `nil` if the value is `nil`.
    ///
    /// - Returns: A `Date` if the value exists, otherwise `nil`.
    public var matrixDate: Date? {
        self?.matrixDate
    }
}
