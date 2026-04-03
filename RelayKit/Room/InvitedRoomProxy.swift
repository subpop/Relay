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

// InvitedRoomProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// An `@Observable` proxy for a room the user has been invited to.
///
/// Provides read-only room information and the ability to accept
/// or reject the invitation.
@Observable
public final class InvitedRoomProxy: InvitedRoomProxyProtocol, @unchecked Sendable {
    private let room: Room

    /// The Matrix room ID.
    public let id: String

    /// The computed display name of the room.
    public let displayName: String?

    /// The room's avatar URL, if set.
    public let avatarURL: URL?

    /// Whether this is a direct message room.
    public private(set) var isDirect: Bool = false

    /// The member who sent the invitation, if available.
    public private(set) var inviter: RoomMember?

    /// Creates an invited room proxy.
    ///
    /// - Parameter room: The SDK room instance.
    public init(room: Room) {
        self.room = room
        self.id = room.id()
        self.displayName = room.displayName()
        self.avatarURL = room.avatarUrl().matrixURL
    }

    /// Loads additional room info that requires async calls.
    public func loadDetails() async {
        self.isDirect = await room.isDirect()
        self.inviter = try? await room.inviter()
    }

    /// Accepts the invitation and joins the room.
    public func accept() async throws {
        try await room.join()
    }

    /// Rejects the invitation.
    public func reject() async throws {
        try await room.leave()
    }
}
