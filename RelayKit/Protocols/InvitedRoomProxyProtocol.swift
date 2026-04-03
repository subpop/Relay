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

// InvitedRoomProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A proxy for a room the user has been invited to.
///
/// Provides read-only room information and the ability to accept
/// or reject the invitation.
///
/// ## Topics
///
/// ### Identity
/// - ``id``
/// - ``displayName``
/// - ``avatarURL``
///
/// ### Invitation
/// - ``inviter``
/// - ``accept()``
/// - ``reject()``
public protocol InvitedRoomProxyProtocol: AnyObject, Sendable {
    /// The Matrix room ID.
    var id: String { get }

    /// The computed display name of the room.
    var displayName: String? { get }

    /// The room's avatar URL, if set.
    var avatarURL: URL? { get }

    /// Whether this is a direct message room.
    var isDirect: Bool { get }

    /// The member who sent the invitation, if available.
    var inviter: RoomMember? { get }

    /// Accepts the invitation and joins the room.
    ///
    /// - Throws: If accepting the invitation fails.
    func accept() async throws

    /// Rejects the invitation.
    ///
    /// - Throws: If rejecting the invitation fails.
    func reject() async throws
}
