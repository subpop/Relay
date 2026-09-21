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
import Testing

@testable import Relay

/// Decision tests for re-pinning the reading position after backward
/// pagination prepends older history.
@Suite("Scroll anchor")
@MainActor
struct TimelineScrollAnchorTests {
    private func pending(
        id: String = "m3",
        rowCount: Int = 3,
        contentHeight: CGFloat = 1000
    ) -> PendingScrollAnchor {
        PendingScrollAnchor(id: id, rowCount: rowCount, contentHeight: contentHeight)
    }

    private func target(
        pending: PendingScrollAnchor? = nil,
        rowIDs: [String] = ["m0", "m1", "m2", "m3"],
        contentHeight: CGFloat = 4000,
        isLoadingMore: Bool = false,
        isNearEnd: Bool = false,
        nearTop: Bool = true
    ) -> String? {
        TimelineScroller.anchorTarget(
            pending: pending ?? self.pending(),
            rowIDs: rowIDs,
            contentHeight: contentHeight,
            isLoadingMore: isLoadingMore,
            isNearEnd: isNearEnd,
            nearTop: nearTop)
    }

    @Test("Returns nil without a pending anchor")
    func noPending() {
        #expect(
            TimelineScroller.anchorTarget(
                pending: nil,
                rowIDs: ["m0", "m3"],
                contentHeight: 4000,
                isLoadingMore: false,
                isNearEnd: false,
                nearTop: true) == nil)
    }

    @Test("Waits while a fetch is in flight")
    func loading() {
        #expect(target(isLoadingMore: true) == nil)
    }

    @Test("Skips when the user is at the live edge")
    func nearEnd() {
        #expect(target(isNearEnd: true) == nil)
    }

    @Test("Skips when the offset rode down with the new content")
    func notNearTop() {
        // The edge anchor did its job: the viewport moved with the prepend.
        #expect(target(nearTop: false) == nil)
    }

    @Test("Skips when the page added no rows")
    func noGrowth() {
        #expect(target(rowIDs: ["m0", "m1", "m2"]) == nil)
    }

    @Test("Skips while prepended content has no realized height")
    func noRealizedHeight() {
        // Lazy rows outside the window contribute no height yet; anchoring
        // now would snap against stale layout.
        #expect(target(contentHeight: 1100) == nil)
    }

    @Test("Skips when the anchor row is gone")
    func anchorMissing() {
        #expect(target(rowIDs: ["m0", "m1", "m2", "m4"]) == nil)
    }

    @Test("Skips when the anchor is still the first row")
    func anchorStillFirst() {
        // Nothing prepended above the reading position (e.g. live arrivals).
        #expect(target(rowIDs: ["m3", "m4", "m5", "m6"]) == nil)
    }

    @Test("Anchors the trigger-time top row after a displacing prepend")
    func displacingPrepend() {
        #expect(target() == "m3")
    }

    @Test("Backfill gate fires once per entry into the top zone")
    func backfillGate() {
        var gate = TimelineScroller.BackfillGate()
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // First entry fires and records the firing time.
        let firstEntry = gate.shouldFire(nearTop: true, now: base)
        #expect(firstEntry)
        // Dwelling in the zone never refires on its own.
        let dwell = gate.shouldFire(nearTop: true, now: base.addingTimeInterval(10))
        #expect(!dwell)
        // Leaving and re-entering after the cooldown fires again.
        let exit = gate.shouldFire(nearTop: false, now: base.addingTimeInterval(10))
        #expect(!exit)
        let reentry = gate.shouldFire(nearTop: true, now: base.addingTimeInterval(11))
        #expect(reentry)
    }

    @Test("Backfill gate cools down rapid re-entries")
    func backfillCooldown() {
        var gate = TimelineScroller.BackfillGate()
        let base = Date(timeIntervalSinceReferenceDate: 2_000_000)

        let firstEntry = gate.shouldFire(nearTop: true, now: base)
        #expect(firstEntry)
        let exit = gate.shouldFire(nearTop: false, now: base)
        #expect(!exit)
        // Re-entry inside the cooldown is ignored, so chained pages pace
        // instead of firing as fast as the network allows.
        let tooSoon = gate.shouldFire(
            nearTop: true,
            now: base.addingTimeInterval(
                TimelineScroller.BackfillGate.cooldown - 0.1))
        #expect(!tooSoon)
        // A rejected re-entry still counts as dwelling, so leaving and
        // re-entering after the cooldown fires.
        let exitAgain = gate.shouldFire(
            nearTop: false,
            now: base.addingTimeInterval(
                TimelineScroller.BackfillGate.cooldown - 0.05))
        #expect(!exitAgain)
        let afterCooldown = gate.shouldFire(
            nearTop: true,
            now: base.addingTimeInterval(
                TimelineScroller.BackfillGate.cooldown + 0.1))
        #expect(afterCooldown)
    }
}
