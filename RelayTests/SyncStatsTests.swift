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

// MARK: - SyncStatsTests

struct SyncStatsTests {
    private func delta(
        timelines: Int = 0,
        toDevice: Int = 0,
        signedKeyCount: Int? = nil
    ) -> SyncDelta {
        let events = (0..<timelines).map { index in
            MessageEvent(
                type: "m.room.message",
                eventId: EventId(unchecked: "$event\(index)"),
                sender: UserId(unchecked: "@alice:example.org"),
                originServerTs: 1_000 * index,
                content: [:])
        }
        let roomId = RoomId(unchecked: "!room:example.org")
        return SyncDelta(
            nextBatch: "s1",
            joined: timelines > 0 ? [roomId: JoinedRoomDelta(timeline: events)] : [:],
            toDevice: (0..<toDevice).map { _ in BasicEvent(type: "m.dummy") },
            signedKeyCount: signedKeyCount)
    }

    @Test func recordingDeltaUpdatesCounters() {
        var stats = RelayClient.SyncStats()
        stats.record(delta: delta(timelines: 3, toDevice: 2, signedKeyCount: 42))
        #expect(stats.totalDeltas == 1)
        #expect(stats.totalTimelineEvents == 3)
        #expect(stats.totalToDeviceEvents == 2)
        #expect(stats.lastOneTimeKeyCount == 42)
        #expect(stats.lastSyncAt != nil)
        #expect(stats.lastSyncError == nil)
    }

    @Test func keyCountPersistsAcrossDeltasWithoutCounts() {
        var stats = RelayClient.SyncStats()
        stats.record(delta: delta(signedKeyCount: 42))
        stats.record(delta: delta())
        #expect(stats.lastOneTimeKeyCount == 42)
        #expect(stats.totalDeltas == 2)
    }

    @Test func ratesCoverTheTrailingWindow() {
        var stats = RelayClient.SyncStats()
        let now = Date()
        stats.record(delta: delta(timelines: 6), at: now.addingTimeInterval(-120))
        stats.record(delta: delta(timelines: 6), at: now)
        let rates = stats.rates(now: now)
        // 2 deltas and 12 events spread over 2 minutes.
        #expect(abs(rates.deltasPerMinute - 1) < 0.001)
        #expect(abs(rates.eventsPerMinute - 6) < 0.001)
    }

    @Test func emptyStatsReportZeroRates() {
        let rates = RelayClient.SyncStats().rates()
        #expect(rates.deltasPerMinute == 0)
        #expect(rates.eventsPerMinute == 0)
    }

    @Test func oldSamplesAgeOutOfRates() {
        var stats = RelayClient.SyncStats()
        let now = Date()
        stats.record(delta: delta(timelines: 100), at: now.addingTimeInterval(-700))
        stats.record(delta: delta(timelines: 2), at: now)
        let rates = stats.rates(now: now)
        // Only the recent delta counts (window floor keeps the divisor sane).
        #expect(abs(rates.deltasPerMinute - 60) < 0.001)
        #expect(abs(rates.eventsPerMinute - 120) < 0.001)
        #expect(stats.samples.count == 1)
    }

    @Test func bucketsCoverTrailingMinutesOldestFirst() throws {
        var stats = RelayClient.SyncStats()
        let now = Date()
        stats.record(delta: delta(timelines: 4), at: now.addingTimeInterval(-150))
        stats.record(delta: delta(timelines: 6), at: now.addingTimeInterval(-30))
        let buckets = stats.buckets(minutes: 10, now: now)
        try #require(buckets.count == 10)
        #expect(buckets.first?.start != buckets.last?.start)
        #expect(buckets.reduce(0) { $0 + $1.deltas } == 2)
        #expect(buckets.reduce(0) { $0 + $1.events } == 10)
        // Minutes without traffic stay empty.
        #expect(buckets.filter { $0.deltas == 0 }.count == 8)
    }

    @Test func bucketsIgnoreSamplesOutsideTheWindow() {
        var stats = RelayClient.SyncStats()
        let now = Date()
        stats.record(delta: delta(timelines: 100), at: now.addingTimeInterval(-700))
        let buckets = stats.buckets(minutes: 10, now: now)
        #expect(buckets.reduce(0) { $0 + $1.events } == 0)
    }

    @Test func recordingErrorsStampsMessageAndTime() {
        var stats = RelayClient.SyncStats()
        stats.recordError("boom")
        #expect(stats.lastSyncError == "boom")
        #expect(stats.lastSyncErrorAt != nil)
    }

    @Test func resetClearsEverything() {
        var stats = RelayClient.SyncStats()
        stats.record(delta: delta(timelines: 1, signedKeyCount: 7))
        stats.recordError("boom")
        stats.reset()
        let fresh = RelayClient.SyncStats()
        #expect(stats.totalDeltas == fresh.totalDeltas)
        #expect(stats.totalTimelineEvents == fresh.totalTimelineEvents)
        #expect(stats.totalToDeviceEvents == fresh.totalToDeviceEvents)
        #expect(stats.lastOneTimeKeyCount == fresh.lastOneTimeKeyCount)
        #expect(stats.lastSyncAt == fresh.lastSyncAt)
        #expect(stats.lastSyncError == fresh.lastSyncError)
        #expect(stats.lastSyncErrorAt == fresh.lastSyncErrorAt)
        #expect(stats.samples.isEmpty)
    }
}
