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

/// The property used to sort the room list.
enum RoomSortOrder: String, CaseIterable {
    case lastMessage
    case name
}

/// The direction in which to sort the room list.
enum RoomSortDirection: String, CaseIterable {
    case ascending
    case descending
}

/// A filter for the type of rooms to display.
enum RoomTypeFilter: String, CaseIterable {
    case all
    case rooms
    case directMessages
}
