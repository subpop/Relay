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
import LiveKit
import RelayInterface
import OSLog

private let logger = Logger(subsystem: "RelayKit", category: "CallViewModel")

/// A concrete ``CallViewModelProtocol`` implementation backed by the LiveKit Swift SDK.
///
/// ``CallViewModel`` owns a `LiveKit.Room` instance and bridges its delegate callbacks
/// into ``@Observable`` state for SwiftUI consumption.
///
/// The inner ``Delegate`` class implements `RoomDelegate` and dispatches all callbacks
/// onto the main actor via `Task { @MainActor in … }` so that UI state mutations are
/// always performed on the correct actor without requiring LiveKit itself to be
/// `@MainActor`-aware.
@Observable
@MainActor
public final class CallViewModel: CallViewModelProtocol {
    public private(set) var state: CallState = .idle
    public private(set) var participants: [CallParticipant] = []
    public private(set) var isLocalCameraEnabled: Bool = false
    public private(set) var isLocalMicrophoneEnabled: Bool = false
    public private(set) var localParticipantID: String?

    private let room = Room()
    private var delegate: Delegate?

    public init() {
        let delegate = Delegate(viewModel: self)
        self.delegate = delegate
        room.add(delegate: delegate)
    }

    // MARK: - CallViewModelProtocol

    public func connect(url: String, token: String) async throws {
        state = .connecting
        do {
            try await room.connect(url: url, token: token)
            localParticipantID = room.localParticipant.identity?.stringValue
            try await room.localParticipant.setCamera(enabled: true)
            try await room.localParticipant.setMicrophone(enabled: true)
            isLocalCameraEnabled = true
            isLocalMicrophoneEnabled = true
            state = .connected
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func disconnect() async {
        await room.disconnect()
        state = .disconnected
        participants = []
        isLocalCameraEnabled = false
        isLocalMicrophoneEnabled = false
        localParticipantID = nil
    }

    public func toggleCamera() async throws {
        let enabled = !isLocalCameraEnabled
        try await room.localParticipant.setCamera(enabled: enabled)
        isLocalCameraEnabled = enabled
    }

    public func toggleMicrophone() async throws {
        let enabled = !isLocalMicrophoneEnabled
        try await room.localParticipant.setMicrophone(enabled: enabled)
        isLocalMicrophoneEnabled = enabled
    }

    public func makeVideoView(for participantID: String) -> NSView? {
        let participant: Participant?
        if room.localParticipant.identity?.stringValue == participantID {
            participant = room.localParticipant
        } else {
            participant = room.remoteParticipants.values.first(where: {
                $0.identity?.stringValue == participantID
            })
        }
        guard let participant,
              let publication = participant.videoTracks.first?.value,
              let track = publication.track as? VideoTrack else {
            return nil
        }
        let videoView = VideoView()
        videoView.track = track
        return videoView
    }

    // MARK: - Participant Sync

    fileprivate func syncParticipants() {
        participants = room.remoteParticipants.values.map { participant in
            CallParticipant(
                id: participant.identity?.stringValue ?? participant.sid?.stringValue ?? UUID().uuidString,
                displayName: participant.name,
                isCameraEnabled: participant.isCameraEnabled(),
                isMicrophoneEnabled: participant.isMicrophoneEnabled(),
                isSpeaking: participant.isSpeaking
            )
        }
    }

    // MARK: - Delegate Bridge

    /// Bridges `RoomDelegate` callbacks — which arrive on an unspecified thread — onto
    /// the main actor so that `CallViewModel`'s `@Observable` state is always mutated
    /// safely.  The class is `@unchecked Sendable` because `viewModel` is a weak reference
    /// that is only read inside `Task { @MainActor in … }` blocks.
    private final class Delegate: RoomDelegate, @unchecked Sendable {
        weak var viewModel: CallViewModel?

        init(viewModel: CallViewModel) {
            self.viewModel = viewModel
        }

        func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldValue: ConnectionState) {
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                switch connectionState {
                case .connected:
                    if viewModel.state != .connected {
                        viewModel.state = .connected
                    }
                case .disconnected:
                    if viewModel.state == .connected {
                        viewModel.state = .disconnected
                    }
                case .reconnecting:
                    logger.info("Call reconnecting")
                default:
                    break
                }
            }
        }

        func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }

        func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }

        func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }

        func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }
    }
}
