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

import SwiftUI

/// Shared display labels for room and space access settings.
///
/// Used by ``InspectorSecurityTab`` and ``InspectorGeneralTab`` to
/// show human-readable descriptions for join rules, history visibility,
/// and related access settings.
enum RoomAccessLabels {

    // MARK: - Join Rule

    static func joinRuleLabel(_ rule: String?) -> String {
        switch rule {
        case "public": String(localized: "Anyone Can Join", comment: "Join rule label: no invitation required")
        case "invite": String(localized: "Invite Only", comment: "Join rule label: an invitation is required")
        case "knock": String(localized: "Request to Join", comment: "Join rule label: users may ask to join and an admin must approve")
        case "restricted": String(localized: "Restricted", comment: "Join rule label: membership is conditional on criteria such as space membership")
        case "knock_restricted": String(localized: "Knock (Restricted)", comment: "Join rule label: combines request-to-join with restricted conditions")
        default: String(localized: "Unknown", comment: "Join rule label shown when the join rule is missing or unrecognized")
        }
    }

    static func joinRuleIcon(_ rule: String?) -> String {
        switch rule {
        case "public": "globe"
        case "invite": "envelope"
        case "knock": "hand.raised"
        default: "questionmark.circle"
        }
    }

    static func joinRuleDescription(_ rule: String?, entityName: String = "room") -> String {
        switch rule {
        case "public": String(localized: "Anyone can join this \(entityName) without an invitation.", comment: "Join rule description; entityName is 'room' or 'space'")
        case "invite": String(localized: "Users must receive an invitation to join this \(entityName).", comment: "Join rule description; entityName is 'room' or 'space'")
        case "knock": String(localized: "Users can request to join. Admins must approve each request.", comment: "Join rule description for the knock rule")
        case "restricted": String(localized: "Users can join if they meet specific conditions.", comment: "Join rule description for the restricted rule")
        default: String(localized: "The join rule for this \(entityName) is not configured.", comment: "Join rule description shown when the join rule is missing; entityName is 'room' or 'space'")
        }
    }

    // MARK: - History Visibility

    static func historyLabel(_ visibility: String?) -> String {
        switch visibility {
        case "world_readable": String(localized: "Anyone (World Readable)", comment: "History visibility label: history is publicly readable without joining")
        case "shared": String(localized: "Full History", comment: "History visibility label: members see all history since the room was created")
        case "invited": String(localized: "Since Invited", comment: "History visibility label: members see history from when they were invited")
        case "joined": String(localized: "Since Joined", comment: "History visibility label: members see history from when they joined")
        default: String(localized: "Unknown", comment: "History visibility label shown when the setting is missing or unrecognized")
        }
    }

    static func historyIcon(_ visibility: String?) -> String {
        switch visibility {
        case "world_readable": "globe"
        case "shared": "person.2"
        case "invited": "envelope"
        case "joined": "person.badge.key"
        default: "questionmark.circle"
        }
    }

    static func historyColor(_ visibility: String?) -> Color {
        switch visibility {
        case "world_readable": .blue
        case "shared": .green
        case "invited": .orange
        case "joined": .secondary
        default: .secondary
        }
    }

    static func historyDescription(_ visibility: String?) -> String {
        switch visibility {
        case "world_readable": String(localized: "Anyone can read the history, even without joining.", comment: "History visibility description for world-readable history")
        case "shared": String(localized: "Members can see the full history from before they joined.", comment: "History visibility description for shared/full history")
        case "invited": String(localized: "Members can see history from the point they were invited.", comment: "History visibility description for since-invited history")
        case "joined": String(localized: "Members can only see history from the point they joined.", comment: "History visibility description for since-joined history")
        default: String(localized: "History visibility is not configured.", comment: "History visibility description shown when the setting is missing")
        }
    }
}
