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

/// A mock ``SpaceHierarchyViewModelProtocol`` for SwiftUI previews.
///
/// Provides static sample data representing a mix of joined rooms, unjoined rooms,
/// and a sub-space. Does not require the Matrix Rust SDK.
@Observable
final class PreviewSpaceHierarchyViewModel: SpaceHierarchyViewModelProtocol {
    var spaceName = "Work"
    var spaceTopic: String? = "Work-related rooms and discussions"
    var spaceAvatarURL: String?
    var spaceMemberCount: UInt64 = 48
    var isJoined: Bool = true
    var canManageChildren: Bool = true
    var children: [SpaceChild]
    var isLoading = false
    var isAtEnd = true

    private let initialChildren: [SpaceChild]

    init(children: [SpaceChild] = PreviewSpaceHierarchyViewModel.sampleChildren) {
        self.children = children
        self.initialChildren = children
    }

    func load() async {
        children = initialChildren
    }

    func loadMore() async {}

    func joinRoom(roomId: String) async throws {
        try? await Task.sleep(for: .milliseconds(500))
    }

    static let sampleChildren: [SpaceChild] = [
        SpaceChild(
            roomId: "!general:matrix.org",
            name: "General",
            topic: "General discussion and announcements",
            memberCount: 42,
            isJoined: true,
            canonicalAlias: "#general:matrix.org"
        ),
        SpaceChild(
            roomId: "!design:matrix.org",
            name: "Design",
            topic: "UI/UX design discussion and reviews",
            memberCount: 15,
            isJoined: true
        ),
        SpaceChild(
            roomId: "!engineering:matrix.org",
            name: "Engineering",
            topic: "Engineering sub-space with backend and frontend channels",
            memberCount: 30,
            roomType: .space,
            isJoined: true,
            childrenCount: 5
        ),
        SpaceChild(
            roomId: "!ops-space:matrix.org",
            name: "Operations",
            topic: "Operations sub-space",
            memberCount: 12,
            roomType: .space,
            childrenCount: 3,
            joinRule: .public
        ),
        SpaceChild(
            roomId: "!marketing:matrix.org",
            name: "Marketing",
            topic: "Campaign planning and brand discussions",
            memberCount: 8,
            joinRule: .public
        ),
        SpaceChild(
            roomId: "!exec:matrix.org",
            name: "Executive",
            topic: "Leadership team only",
            memberCount: 4,
            joinRule: .invite
        ),
        SpaceChild(
            roomId: "!random:matrix.org",
            name: "Random",
            topic: "Off-topic chat and fun stuff",
            memberCount: 35,
            isJoined: true,
            canonicalAlias: "#random:matrix.org"
        )
    ]
}
