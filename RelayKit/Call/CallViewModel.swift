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
    /// Incremented whenever video tracks change, triggering SwiftUI to
    /// re-call `updateNSView` on any `VideoViewRepresentable`.
    public private(set) var videoTrackRevision: UInt = 0

    private let room = LiveKit.Room()
    private var delegate: Delegate?
    /// Cached `VideoView` instances keyed by participant identity.
    /// Re-used across `makeVideoView(for:)` calls so the view stays stable
    /// even as SwiftUI re-renders, and the `.track` is updated in place
    /// when tracks change.
    private var videoViews: [String: VideoView] = [:]

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
            let identity = room.localParticipant.identity?.stringValue
            localParticipantID = identity
            logger.info("[CallVM] Connected. localParticipantID=\(identity ?? "nil")")

            try await room.localParticipant.setCamera(enabled: true)
            logger.info("[CallVM] setCamera(enabled: true) returned")

            // Log local video tracks immediately after setCamera
            let localPubs = room.localParticipant.videoTracks
            logger.info("[CallVM] localParticipant.videoTracks.count=\(localPubs.count)")
            for pub in localPubs {
                let hasTrack = pub.track != nil
                let trackType = pub.track.map { String(describing: type(of: $0)) } ?? "nil"
                logger.info("[CallVM]   pub sid=\(pub.sid.stringValue), hasTrack=\(hasTrack), trackType=\(trackType), source=\(String(describing: pub.source))")
            }

            try await room.localParticipant.setMicrophone(enabled: true)
            logger.info("[CallVM] setMicrophone(enabled: true) returned")

            isLocalCameraEnabled = true
            isLocalMicrophoneEnabled = true
            state = .connected
            videoTrackRevision += 1

            // Delayed re-check: log track state after 1 second
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let pubs = self.room.localParticipant.videoTracks
                logger.info("[CallVM] Delayed check: videoTracks.count=\(pubs.count)")
                for pub in pubs {
                    let hasTrack = pub.track != nil
                    let isVideoTrack = pub.track is VideoTrack
                    logger.info("[CallVM]   Delayed: pub sid=\(pub.sid.stringValue), hasTrack=\(hasTrack), isVideoTrack=\(isVideoTrack)")
                }
                self.videoTrackRevision += 1
                logger.info("[CallVM] Delayed videoTrackRevision bump to \(self.videoTrackRevision)")
            }
        } catch {
            logger.error("[CallVM] Connect failed: \(error.localizedDescription)")
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
        videoViews.removeAll()
    }

    public func toggleCamera() async throws {
        let enabled = !isLocalCameraEnabled
        try await room.localParticipant.setCamera(enabled: enabled)
        isLocalCameraEnabled = enabled
        videoTrackRevision += 1
        // Same delayed retry as connect — the track may not be attached yet.
        if enabled {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.videoTrackRevision += 1
            }
        }
    }

    public func toggleMicrophone() async throws {
        let enabled = !isLocalMicrophoneEnabled
        try await room.localParticipant.setMicrophone(enabled: enabled)
        isLocalMicrophoneEnabled = enabled
    }

    public func makeVideoView(for participantID: String) -> NSView? {
        let participant: Participant?
        let isLocal = room.localParticipant.identity?.stringValue == participantID
        if isLocal {
            participant = room.localParticipant
        } else {
            participant = room.remoteParticipants.values.first(where: {
                $0.identity?.stringValue == participantID
            })
        }

        let foundParticipant = participant != nil
        let allPubCount = participant?.trackPublications.count ?? 0
        let videoPubCount = participant?.videoTracks.count ?? 0
        logger.info("[CallVM] makeVideoView(for: \(participantID)) isLocal=\(isLocal), found=\(foundParticipant), allPubs=\(allPubCount), videoPubs=\(videoPubCount)")

        // Look up the current video track (may be nil if not yet published).
        let firstPub = participant?.videoTracks.first
        let rawTrack = firstPub?.track
        let track = rawTrack as? VideoTrack

        logger.info("[CallVM]   firstPub=\(firstPub != nil), rawTrack=\(rawTrack != nil), rawTrackType=\(rawTrack.map { String(describing: type(of: $0)) } ?? "nil"), castOK=\(track != nil)")

        // Return or create a cached VideoView. Its `.track` is updated in
        // place every call so the rendered content stays current even when
        // the underlying track changes (e.g. camera toggled on/off).
        if let existing = videoViews[participantID] {
            existing.track = track
            logger.info("[CallVM]   Reusing cached VideoView, track set to \(track != nil ? "non-nil" : "nil")")
            return existing
        }

        let videoView = VideoView()
        videoView.track = track
        videoViews[participantID] = videoView
        logger.info("[CallVM]   Created new VideoView, track set to \(track != nil ? "non-nil" : "nil")")
        return videoView
    }

    // MARK: - Participant Sync

    fileprivate func syncParticipants() {
        videoTrackRevision += 1
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

        func room(_ room: LiveKit.Room, didUpdateConnectionState connectionState: LiveKit.ConnectionState, from oldValue: LiveKit.ConnectionState) {
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

        func room(_ room: LiveKit.Room, participantDidConnect participant: RemoteParticipant) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }

        func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }

        func room(_ room: LiveKit.Room, didUpdateSpeakingParticipants participants: [Participant]) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }

        func room(_ room: LiveKit.Room, localParticipant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
            Task { @MainActor [weak viewModel] in
                logger.info("Local track published: \(String(describing: publication.kind))")
                viewModel?.videoTrackRevision += 1
            }
        }

        func room(_ room: LiveKit.Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
            Task { @MainActor [weak viewModel] in
                viewModel?.syncParticipants()
            }
        }
    }
}
