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

/// A record of content shared via the share extension that is waiting to be sent.
///
/// The share extension writes ``PendingShare`` records to the app group container.
/// The main app reads them, sends the attachments via the Matrix SDK, and removes
/// the records once sent.
public struct PendingShare: Codable, Sendable, Identifiable {
    /// A unique identifier for this pending share.
    public let id: UUID

    /// The Matrix room ID to send the content to.
    public let roomId: String

    /// Relative paths of shared files within the app group container's
    /// `pending-shares/` directory.
    public let filenames: [String]

    /// The time the share was created.
    public let timestamp: Date

    public init(id: UUID = UUID(), roomId: String, filenames: [String], timestamp: Date = .now) {
        self.id = id
        self.roomId = roomId
        self.filenames = filenames
        self.timestamp = timestamp
    }
}
