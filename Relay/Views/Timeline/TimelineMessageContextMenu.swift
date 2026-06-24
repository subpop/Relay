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

import RelayInterface

/// Ordered contextual-menu sections for a timeline bubble (SwiftUI + NSTextView).
enum TimelineMessageContextMenuEntry: Equatable {
    case reply
    case copyMessage
    case addReaction
    case togglePin
    case edit
    case separatorBeforeDelete
    case delete
}

enum TimelineMessageContextMenu {
    /// Entries shown for a normal (non-system) timeline message row.
    ///
    /// - Parameters:
    ///   - message: The timeline message to build context menu entries for.
    ///   - permissions: The current user's room-level permissions. When `nil`
    ///     (e.g. in previews), actions default to standard user capabilities.
    static func entries(
        for message: TimelineMessage,
        permissions: RoomPermissions? = nil
    ) -> [TimelineMessageContextMenuEntry] {
        let canSend = permissions?.canSendMessages ?? true

        var result: [TimelineMessageContextMenuEntry] = [.copyMessage]
        if canSend {
            result.insert(.reply, at: 0)
            result.append(.addReaction)
        }
        if (permissions?.canPin ?? false) && message.eventID.hasPrefix("$") {
            result.append(.togglePin)
        }
        if message.isOutgoing && message.kind == .text && canSend {
            result.append(.edit)
        }
        if (message.isOutgoing || (permissions?.canRedactOther ?? false))
            && message.kind != .redacted {
            result.append(.separatorBeforeDelete)
            result.append(.delete)
        }
        return result
    }
}

/// Actions that timeline rows request via ``TimelineRowView/onContextAction``.
enum TimelineRowContextAction {
    case reply(TimelineMessage)
    case copy(String)
    case togglePin(String)
    case edit(TimelineMessage)
    case delete(TimelineMessage)
    /// Run an on-device translation of the message into the user's locale.
    case translate(TimelineMessage)
    /// Drop a previously-applied translation, returning the row to the
    /// original-language body.
    case showOriginal(TimelineMessage)
}
