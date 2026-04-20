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
import RelayInterface

/// A mock implementation of ``RoomDirectoryViewModelProtocol`` for use in SwiftUI previews.
///
/// Returns static sample directory rooms. Search filters client-side; pagination is a no-op.
@Observable
final class PreviewRoomDirectoryViewModel: RoomDirectoryViewModelProtocol {
    var rooms: [DirectoryRoom] = PreviewRoomDirectoryViewModel.sampleRooms
    var isSearching = false
    var isAtEnd = true

    func search(query: String?) async {
        isSearching = true
        try? await Task.sleep(for: .milliseconds(200))
        if let query, !query.isEmpty {
            rooms = Self.sampleRooms.filter {
                ($0.name ?? "").localizedCaseInsensitiveContains(query)
                    || ($0.alias ?? "").localizedCaseInsensitiveContains(query)
            }
        } else {
            rooms = Self.sampleRooms
        }
        isSearching = false
    }

    func loadMore() async {}

    static let sampleRooms: [DirectoryRoom] = [
        DirectoryRoom(
            roomId: "!matrix-hq:matrix.org", name: "Matrix HQ",
            topic: "The official Matrix community room. Come say hello!",
            alias: "#matrix-hq:matrix.org", memberCount: 8500,
            isWorldReadable: true
        ),
        DirectoryRoom(
            roomId: "!community-space:matrix.org", name: "Matrix Community",
            topic: "The official Matrix community space",
            alias: "#community:matrix.org", memberCount: 12000,
            isSpace: true
        ),
        DirectoryRoom(
            roomId: "!swift:matrix.org", name: "Swift Developers",
            topic: "All things Swift programming language",
            alias: "#swift:matrix.org", memberCount: 1200,
            isWorldReadable: true
        ),
        DirectoryRoom(
            roomId: "!design:matrix.org", name: "Design Team",
            topic: "UI/UX design discussion and feedback",
            alias: "#design:matrix.org", memberCount: 42
        ),
        DirectoryRoom(
            roomId: "!opensource-space:matrix.org", name: "Open Source",
            topic: "Open source projects and collaboration",
            alias: "#opensource:matrix.org", memberCount: 5400,
            isSpace: true
        ),
        DirectoryRoom(
            roomId: "!rust:matrix.org", name: "Rust Programming",
            topic: "Discuss Rust, share crates, and get help with borrow checker issues",
            alias: "#rust:matrix.org", memberCount: 650,
            isWorldReadable: true
        ),
        DirectoryRoom(
            roomId: "!linux:matrix.org", name: "Linux Users",
            topic: "Linux discussion, tips, and support",
            alias: "#linux:matrix.org", memberCount: 3200
        ),
        DirectoryRoom(
            roomId: "!privacy:matrix.org", name: "Privacy & Security",
            topic: "Discuss online privacy, encryption, and security best practices",
            alias: "#privacy:matrix.org", memberCount: 890,
            isWorldReadable: true
        )
    ]
}
