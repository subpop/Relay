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

extension DefaultNotificationMode {
    /// Short human-readable label for settings pickers.
    var label: String {
        switch self {
        case .allMessages: String(localized: "All Messages", comment: "Notification mode label: notify for every message")
        case .mentionsAndKeywordsOnly: String(localized: "Mentions and Keywords Only", comment: "Notification mode label: notify only for @mentions and configured keywords")
        case .mute: String(localized: "Mute", comment: "Notification mode label (noun, not a verb): all notifications are silenced")
        }
    }
}

extension RoomNotificationMode {
    /// Short human-readable label for per-room override rows.
    var label: String {
        switch self {
        case .allMessages: String(localized: "All Messages", comment: "Per-room notification override label: notify for every message")
        case .mentionsAndKeywordsOnly: String(localized: "Mentions Only", comment: "Per-room notification override label: notify only for @mentions")
        case .mute: String(localized: "Mute", comment: "Per-room notification override label (noun, not a verb): notifications silenced for this room")
        }
    }

    /// SF Symbol icon name for display alongside the label.
    var icon: String {
        switch self {
        case .allMessages: "bell.fill"
        case .mentionsAndKeywordsOnly: "at"
        case .mute: "bell.slash"
        }
    }
}
