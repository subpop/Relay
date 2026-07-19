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

import AppKit
import Testing

@testable import Relay

// MARK: - MessageTextScaleTests
//
// These tests mutate MessageTextScale's persisted state via increase() /
// decrease() / reset(), unlike other suites that only ever read it. Reading
// and writing a real, shared UserDefaults.standard key from concurrently
// running tests is a genuine race (confirmed: an early version of this file
// intermittently pushed MatrixHTMLParserTests.headingFontSizes() to read a
// scale of 2.4 mid-run). Redirect MessageTextScale to a private, throwaway
// UserDefaults suite for the duration of this suite, and serialize its own
// tests so they can't race the swap against each other either.
@Suite(.serialized)
@MainActor
struct MessageTextScaleTests {

    init() {
        MessageTextScale.userDefaults = UserDefaults(suiteName: "MessageTextScaleTests.\(UUID())")!
    }

    @Test func resetRestoresDefaultScale() {
        MessageTextScale.increase()
        MessageTextScale.increase()
        MessageTextScale.reset()
        #expect(MessageTextScale.scale == MessageTextScale.defaultScale)
    }

    @Test func increaseAndDecreaseAreSymmetric() {
        MessageTextScale.reset()
        let base = MessageTextScale.scale
        MessageTextScale.increase()
        MessageTextScale.decrease()
        #expect(abs(MessageTextScale.scale - base) < 0.001, "One increase followed by one decrease must return to the starting scale.")
    }

    @Test func increaseClampsAtMaxScaleWithoutOvershoot() {
        MessageTextScale.reset()
        for _ in 0 ..< 100 {
            MessageTextScale.increase()
        }
        #expect(MessageTextScale.scale == MessageTextScale.maxScale, "Repeated increases must clamp at maxScale, not overshoot it.")
    }

    @Test func decreaseClampsAtMinScaleWithoutUndershoot() {
        MessageTextScale.reset()
        for _ in 0 ..< 100 {
            MessageTextScale.decrease()
        }
        #expect(MessageTextScale.scale == MessageTextScale.minScale, "Repeated decreases must clamp at minScale, not undershoot it.")
    }

    @Test func changeAtLimitDoesNotRepostNotificationForANoOp() async {
        MessageTextScale.reset()
        for _ in 0 ..< 100 {
            MessageTextScale.increase()
        }
        // At the ceiling, `scale` is already `maxScale`.
        #expect(MessageTextScale.scale == MessageTextScale.maxScale)

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: MessageTextScale.didChangeNotification, object: nil, queue: nil
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        MessageTextScale.increase() // Already at the ceiling: must be a no-op.
        #expect(!notified, "Hitting the clamp again must not repost didChangeNotification (would needlessly churn the timeline).")
    }

    @Test func baseFontSizeTracksScale() {
        MessageTextScale.reset()
        let unscaled = MessageTextScale.baseFontSize
        #expect(unscaled == NSFont.systemFontSize)

        MessageTextScale.increase()
        #expect(MessageTextScale.baseFontSize > unscaled, "baseFontSize must grow as the scale increases.")
        #expect(MessageTextScale.baseFontSize == NSFont.systemFontSize * MessageTextScale.scale)
    }

    @Test func baseFontPointSizeMatchesBaseFontSize() {
        MessageTextScale.reset()
        MessageTextScale.increase()
        #expect(MessageTextScale.baseFont.pointSize == MessageTextScale.baseFontSize)
    }

    @Test func clampBoundsRawValuesToMinAndMax() {
        #expect(MessageTextScale.clamp(MessageTextScale.minScale - 10) == MessageTextScale.minScale)
        #expect(MessageTextScale.clamp(MessageTextScale.maxScale + 10) == MessageTextScale.maxScale)
        let mid = (MessageTextScale.minScale + MessageTextScale.maxScale) / 2
        #expect(MessageTextScale.clamp(mid) == mid)
    }
}
