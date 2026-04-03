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

// KnockedRoomProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A proxy for a room the user has knocked on (requested to join).
///
/// Provides read-only room information and the ability to cancel
/// the knock request.
///
/// ## Topics
///
/// ### Identity
/// - ``id``
/// - ``displayName``
///
/// ### Actions
/// - ``cancelKnock()``
public protocol KnockedRoomProxyProtocol: AnyObject, Sendable {
    /// The Matrix room ID.
    var id: String { get }

    /// The computed display name of the room.
    var displayName: String? { get }

    /// The room's avatar URL, if set.
    var avatarURL: URL? { get }

    /// Cancels the pending knock request by leaving the room.
    ///
    /// - Throws: If cancelling the knock fails.
    func cancelKnock() async throws
}
