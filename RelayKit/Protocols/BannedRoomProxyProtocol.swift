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

// BannedRoomProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A proxy for a room the user has been banned from.
///
/// Provides read-only room information and the ability to forget
/// the room, removing it from the user's room list.
///
/// ## Topics
///
/// ### Identity
/// - ``id``
/// - ``displayName``
///
/// ### Actions
/// - ``forget()``
public protocol BannedRoomProxyProtocol: AnyObject, Sendable {
    /// The Matrix room ID.
    var id: String { get }

    /// The computed display name of the room.
    var displayName: String? { get }

    /// The room's avatar URL, if set.
    var avatarURL: URL? { get }

    /// Forgets the room, removing it from the room list.
    ///
    /// - Throws: If forgetting the room fails.
    func forget() async throws
}
