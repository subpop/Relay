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

import Observation
import RelayInterface

/// Tracks how far through the timeline the user has read and issues read
/// receipts.
///
/// Lives in ``TimelineView``. The view decides *when* to advance the tracker
/// (on scroll settled, on visible messages changing, on window activation);
/// the tracker owns the debounced fully-read-marker advance and the end-of-
/// timeline mark-as-read call.
@MainActor
@Observable
final class TimelineReadReceiptTracker {
    private var lastFullyReadEventId: String?
    private var fullyReadDebounceTask: Task<Void, Never>?

    /// Debounced advance of the fully-read marker. Ignores moves backwards
    /// from the already-recorded high-water mark.
    ///
    /// - Parameters:
    ///   - eventId: The event id of the newest message currently visible.
    ///   - messages: All loaded messages, to compare indices.
    ///   - sendReceipt: Called (debounced) with the event to read up to.
    func updateHighWaterMark(eventId: String, in messages: [TimelineMessage], sendReceipt: @escaping (String) async -> Void) {
        if let lastId = lastFullyReadEventId,
           let lastIndex = messages.firstIndex(where: { $0.eventID == lastId }),
           let newIndex = messages.firstIndex(where: { $0.eventID == eventId }),
           newIndex <= lastIndex {
            return
        }

        lastFullyReadEventId = eventId
        fullyReadDebounceTask?.cancel()
        fullyReadDebounceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await sendReceipt(eventId)
        }
    }

    /// Marks the room read if the user is at the end of the live timeline and
    /// the app is active.
    func markReadIfNeeded(isNearEnd: Bool, isActive: Bool, markAsRead: @escaping () async -> Void) {
        guard isNearEnd, isActive else { return }
        Task { await markAsRead() }
    }
}
