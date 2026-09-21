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

/// Relay-level display classification for direct chats.
///
/// MatrixKit's `ObservableRoom.isDirect` is spec-pure (`m.direct` account
/// data only). For display and behavior defaults, Relay additionally treats
/// a room as DM-like when it has no public alias and two or fewer joined
/// members. This is computed on demand, never stored, so partial member
/// lists under lazy loading can never latch a wrong value.
enum RoomPresentation {
    static func presentsAsDirect(
        isDirect: Bool, isSpace: Bool, canonicalAlias: String?, joinedMemberCount: Int
    ) -> Bool {
        isDirect || (!isSpace && canonicalAlias == nil && joinedMemberCount <= 2)
    }
}

extension ObservableRoom {
    /// Spec `m.direct`, or the Relay DM-like display heuristic.
    var presentsAsDirect: Bool {
        RoomPresentation.presentsAsDirect(
            isDirect: isDirect,
            isSpace: isSpace,
            canonicalAlias: canonicalAlias,
            joinedMemberCount: memberDetails.values.filter { $0.membership == .join }.count)
    }

    /// Avatar for list rows: the room avatar, falling back to the other
    /// joined member's avatar when the room presents as a direct chat
    /// (DMs carry no room avatar).
    var presentingAvatarURL: MXCURI? {
        if let avatarURL { return avatarURL }
        guard presentsAsDirect else { return nil }
        return memberDetails
            .first { $0.key != localUserId && $0.value.membership == .join }?
            .value.avatarUrl
            .flatMap { try? MXCURI($0) }
    }
}
