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

// RoomProxyType.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// Represents the membership-specific type of a room proxy.
///
/// Each case wraps a protocol appropriate for the user's membership
/// state in that room, providing only the operations valid for that state.
///
/// ## Topics
///
/// ### Cases
/// - ``joined(_:)``
/// - ``invited(_:)``
/// - ``knocked(_:)``
/// - ``banned(_:)``
/// - ``left``
public enum RoomProxyType: Sendable {
    /// A room the user has joined with full access.
    case joined(any JoinedRoomProxyProtocol)

    /// A room the user has been invited to.
    case invited(any InvitedRoomProxyProtocol)

    /// A room the user has knocked on (requested to join).
    case knocked(any KnockedRoomProxyProtocol)

    /// A room the user has been banned from.
    case banned(any BannedRoomProxyProtocol)

    /// A room the user has left.
    case left
}
