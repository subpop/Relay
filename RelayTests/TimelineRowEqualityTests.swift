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
import MatrixKit
import Testing

@testable import Relay

@Suite("Timeline row equality")
@MainActor
struct TimelineRowEqualityTests {
    @Test func senderDisplayNameChangeInvalidatesRow() {
        let old = event("message", displayName: "Alice")
        let updated = event("message", displayName: "Alicia")

        #expect(row(old) != row(updated))
    }

    @Test func senderAvatarChangeInvalidatesRow() {
        let old = event("message", avatarURL: "mxc://example.org/old")
        let updated = event("message", avatarURL: "mxc://example.org/new")

        #expect(row(old) != row(updated))
    }

    @Test func membershipTargetDisplayNameChangeInvalidatesRow() {
        let old = event(
            "membership", kind: .state(type: "m.room.member", description: "Removed Bob"),
            targetDisplayName: "Bob")
        let updated = event(
            "membership", kind: .state(type: "m.room.member", description: "Removed Bob"),
            targetDisplayName: "Robert")

        #expect(row(old) != row(updated))
    }

    @Test func profileChangeInCollapsedEventsInvalidatesRow() {
        let first = event("first", kind: .profileChange(description: "Profile changed"))
        let oldLaterEvent = event("later", displayName: "Alice")
        let updatedLaterEvent = event("later", displayName: "Alicia")

        #expect(row(first, collapsed: [first, oldLaterEvent])
            != row(first, collapsed: [first, updatedLaterEvent]))
    }

    private func event(
        _ id: String,
        displayName: String? = nil,
        avatarURL: String? = nil,
        kind: MessageKind = .text(body: "Hello"),
        targetDisplayName: String? = nil
    ) -> ObservableTimelineEvent {
        ObservableTimelineEvent(
            eventId: EventId(unchecked: "$\(id)"),
            sender: UserId(unchecked: "@alice:example.org"),
            timestamp: .now,
            kind: kind,
            senderDisplayName: displayName,
            senderAvatarURL: avatarURL.flatMap { try? MXCURI($0) },
            targetUserId: targetDisplayName.map { _ in UserId(unchecked: "@bob:example.org") },
            targetDisplayName: targetDisplayName
        )
    }

    private func row(
        _ message: ObservableTimelineEvent,
        collapsed: [ObservableTimelineEvent]? = nil
    ) -> TimelineRowView {
        TimelineRowView(
            row: MessageRow(
                message: message,
                info: MessageGroupInfo(),
                isPaginationTrigger: false,
                collapsedSystemEvents: collapsed
            ),
            isHighlighted: false,
            isUnreadDivider: false,
            showURLPreviews: true,
            onAppear: { _ in }
        )
    }
}
