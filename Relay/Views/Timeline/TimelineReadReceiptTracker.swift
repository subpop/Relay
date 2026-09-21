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

import MatrixKit
import Observation

/// Tracks how far through the timeline the user has read and issues read
/// receipts.
///
/// Lives in ``TimelineView``. The view decides *when* to advance the tracker
/// (on scroll settled, on visible messages changing, on app reactivation);
/// the tracker owns the debounced fully-read-marker advance and the end-of-
/// timeline mark-as-read call.
@MainActor
@Observable
final class TimelineReadReceiptTracker {
    private var lastFullyReadEventId: String?
    private var fullyReadDebounceTask: Task<Void, Never>?
    private var markReadDebounceTask: Task<Void, Never>?

    /// Debounced advance of the fully-read marker. Ignores moves backwards
    /// from the already-recorded high-water mark. While the app is inactive
    /// the high-water mark is still recorded but no send is scheduled; the
    /// view re-advances on reactivation.
    ///
    /// - Parameters:
    ///   - eventId: The event id of the newest message currently visible.
    ///   - messages: All loaded messages, to compare indices.
    ///   - isActive: Whether the app currently has focus.
    ///   - sendReceipt: Called (debounced) with the event to read up to.
    func updateHighWaterMark(eventId: String, in messages: [ObservableTimelineEvent], isActive: Bool, sendReceipt: @escaping (String) async -> Void) {
        if let lastId = lastFullyReadEventId,
           let lastIndex = messages.firstIndex(where: { $0.eventId.value == lastId }),
           let newIndex = messages.firstIndex(where: { $0.eventId.value == eventId }),
           newIndex <= lastIndex {
            return
        }

        lastFullyReadEventId = eventId
        fullyReadDebounceTask?.cancel()
        guard isActive else { return }
        fullyReadDebounceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await sendReceipt(eventId)
        }
    }

    /// Marks the room read if the user is at the end of the live timeline and
    /// the app is active. Debounced with a 3-second dwell so bursts of
    /// triggers (scroll ticks, incoming message batches, loading
    /// transitions) coalesce into a single send once settled, and newly
    /// arrived messages sit unread briefly while being read. The latest
    /// call's values win, so scrolling away cancels a pending mark.
    func markReadIfNeeded(isNearEnd: Bool, isActive: Bool, markAsRead: @escaping () async -> Void) {
        markReadDebounceTask?.cancel()
        markReadDebounceTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard isNearEnd, isActive else { return }
            await markAsRead()
        }
    }
}
