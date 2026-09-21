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
import Intents
import os

private let logger = Logger(subsystem: "Relay", category: "IntentDonation")

/// Donates `INSendMessageIntent` interactions so macOS can suggest Relay
/// conversations in the system share sheet.
///
/// The service maintains a per-room debounce for incoming message donations
/// to avoid excessive system calls. Outgoing donations happen once per send.
@MainActor
final class IntentDonationService {

    /// Minimum interval between incoming-message donations for the same room.
    private let incomingDebounceInterval: TimeInterval = 60

    /// Tracks the last donation timestamp per room ID for incoming messages.
    private var lastIncomingDonation: [String: Date] = [:]

    init() {}

    // MARK: - Outgoing

    /// Donates an outgoing message intent for a conversation.
    ///
    /// Call this after a message is successfully sent. The donated intent
    /// teaches the system that the user actively communicates in this room.
    ///
    /// - Parameter roomSummary: The summary of the room the message was sent to.
    func donateOutgoingMessage(roomId: String, roomName: String) {
        let intent = makeSendMessageIntent(roomId: roomId, roomName: roomName)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing

        Task {
            do {
                try await interaction.donate()
            } catch {
                logger.error("Failed to donate outgoing intent for \(roomId, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Incoming

    /// Donates an incoming message intent for a conversation.
    ///
    /// Debounced to at most once per room per ``incomingDebounceInterval``.
    ///
    /// - Parameters:
    ///   - roomSummary: The summary of the room the message was received in.
    ///   - senderName: The display name of the message sender.
    func donateIncomingMessage(roomId: String, roomName: String, senderName: String?) {
        let now = Date()
        if let last = lastIncomingDonation[roomId],
           now.timeIntervalSince(last) < incomingDebounceInterval {
            return
        }
        lastIncomingDonation[roomId] = now

        let sender: INPerson? = senderName.map { name in
            INPerson(
                personHandle: INPersonHandle(value: nil, type: .unknown),
                nameComponents: nil,
                displayName: name,
                image: nil,
                contactIdentifier: nil,
                customIdentifier: nil
            )
        }

        let intent = makeSendMessageIntent(roomId: roomId, roomName: roomName, sender: sender)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming

        Task {
            do {
                try await interaction.donate()
            } catch {
                logger.error("Failed to donate incoming intent for \(roomId, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private func makeSendMessageIntent(
        roomId: String,
        roomName: String,
        sender: INPerson? = nil
    ) -> INSendMessageIntent {
        let groupName = INSpeakableString(spokenPhrase: roomName)
        return INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: groupName,
            conversationIdentifier: roomId,
            serviceName: "Relay",
            sender: sender,
            attachments: nil
        )
    }
}
