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

// MARK: - Room List Environment

private struct RoomListMeasuredWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The room list's settled content width, measured once by the
    /// containing `List` in ``RoomListView`` and held steady while the list
    /// is actively scrolling.
    ///
    /// A dragged `NSScroller` can transiently perturb the list's measured
    /// width right at a row's compact/full breakpoint; measuring once at
    /// the list level (instead of once per row) and deferring updates until
    /// scrolling settles prevents every visible row from flipping styles
    /// independently mid-drag.
    ///
    /// `nil` when no ancestor has supplied one — rows fall back to
    /// measuring their own frame in that case (e.g. a row rendered
    /// standalone in an Xcode preview).
    var roomListMeasuredWidth: CGFloat? {
        get { self[RoomListMeasuredWidthKey.self] }
        set { self[RoomListMeasuredWidthKey.self] = newValue }
    }
}
