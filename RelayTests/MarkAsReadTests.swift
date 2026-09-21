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

import Testing

@testable import Relay

// MARK: - MarkAsReadTests

struct MarkAsReadTests {
    @Test func noPriorMarkAlwaysSends() {
        #expect(RelayClient.shouldSendMark(
            lastMarked: nil, latestEventId: "$a", sendReceipt: true))
        #expect(RelayClient.shouldSendMark(
            lastMarked: nil, latestEventId: "$a", sendReceipt: false))
    }

    @Test func newEventAlwaysSends() {
        #expect(RelayClient.shouldSendMark(
            lastMarked: ("$a", true), latestEventId: "$b", sendReceipt: true))
        #expect(RelayClient.shouldSendMark(
            lastMarked: ("$a", false), latestEventId: "$b", sendReceipt: false))
    }

    @Test func sameEventSkipsWhenNothingNewToSend() {
        // Receipt already sent: repeat triggers post nothing.
        #expect(!RelayClient.shouldSendMark(
            lastMarked: ("$a", true), latestEventId: "$a", sendReceipt: true))
        // Receipts off and fully-read already sent.
        #expect(!RelayClient.shouldSendMark(
            lastMarked: ("$a", false), latestEventId: "$a", sendReceipt: false))
    }

    @Test func sameEventRetriesUnsentReceipt() {
        // The earlier receipt failed (or the setting was flipped on) but
        // fully-read succeeded: a receipt is now requested that was never
        // sent, so the mark must re-fire instead of staying suppressed.
        #expect(RelayClient.shouldSendMark(
            lastMarked: ("$a", false), latestEventId: "$a", sendReceipt: true))
    }

    @Test func receiptTypeIsPrivateWhenReceiptsOff() {
        // Public receipts share read state; a private receipt clears the
        // server's unread count without showing other members what was
        // read.
        #expect(RelayClient.receiptType(sendReceipt: true) == "m.read")
        #expect(RelayClient.receiptType(sendReceipt: false) == "m.read.private")
    }

    @Test func localEchoesAreNotMarkable() {
        #expect(!RelayClient.isMarkableEventId("local:txn1"))
        #expect(RelayClient.isMarkableEventId("$abc"))
    }

    @Test func newestMarkableSkipsTrailingEchoes() {
        #expect(RelayClient.newestMarkableEventId(in: ["$a", "$b", "local:txn1"]) == "$b")
        #expect(RelayClient.newestMarkableEventId(in: ["$a", "$b"]) == "$b")
        #expect(RelayClient.newestMarkableEventId(in: ["local:txn1"]) == nil)
        #expect(RelayClient.newestMarkableEventId(in: []) == nil)
    }
}
