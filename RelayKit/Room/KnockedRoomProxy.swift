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

// KnockedRoomProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// An `@Observable` proxy for a room the user has knocked on.
///
/// Provides read-only room information and the ability to cancel
/// the knock request.
@Observable
public final class KnockedRoomProxy: KnockedRoomProxyProtocol, @unchecked Sendable {
    private let room: Room

    /// The Matrix room ID.
    public let id: String

    /// The computed display name of the room.
    public let displayName: String?

    /// The room's avatar URL, if set.
    public let avatarURL: URL?

    /// Creates a knocked room proxy.
    ///
    /// - Parameter room: The SDK room instance.
    public init(room: Room) {
        self.room = room
        self.id = room.id()
        self.displayName = room.displayName()
        self.avatarURL = room.avatarUrl().matrixURL
    }

    /// Cancels the pending knock request by leaving the room.
    public func cancelKnock() async throws {
        try await room.leave()
    }
}
