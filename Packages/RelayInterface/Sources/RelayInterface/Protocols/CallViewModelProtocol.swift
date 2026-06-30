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
import SwiftUI

/// The connection state of a call.
public enum CallState: Sendable, Equatable {
    /// No active call.
    case idle
    /// Establishing connection to the call server.
    case connecting
    /// Successfully connected; media is flowing.
    case connected
    /// The call ended cleanly.
    case disconnected
    /// The call failed with an error message.
    case failed(String)
}

/// A snapshot of a single call participant.
public struct CallParticipant: Identifiable, Sendable, Equatable {
    /// The participant's identity string (typically their Matrix user ID).
    public let id: String
    /// The participant's display name, if available.
    public let displayName: String?
    /// Whether the participant has their camera enabled.
    public let isCameraEnabled: Bool
    /// Whether the participant has their microphone enabled.
    public let isMicrophoneEnabled: Bool
    /// Whether the participant is currently speaking.
    public let isSpeaking: Bool

    public init(
        id: String,
        displayName: String?,
        isCameraEnabled: Bool,
        isMicrophoneEnabled: Bool,
        isSpeaking: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.isCameraEnabled = isCameraEnabled
        self.isMicrophoneEnabled = isMicrophoneEnabled
        self.isSpeaking = isSpeaking
    }
}

/// The view model protocol for a LiveKit-backed audio/video call in a Matrix room.
///
/// ``CallViewModelProtocol`` defines the observable state and actions needed by ``CallView``
/// to render the call UI, control local media, and display remote participants. Concrete
/// implementations include ``CallViewModel`` (backed by the LiveKit Swift SDK) and
/// ``PreviewCallViewModel`` (for SwiftUI previews).
///
/// Video rendering is intentionally opaque: callers request an ``NSView`` via
/// ``makeVideoView(for:)`` to avoid exposing LiveKit types outside of RelayKit.
@MainActor
public protocol CallViewModelProtocol: AnyObject, Observable {
    /// The current connection state of the call.
    var state: CallState { get }

    /// All remote participants currently in the call.
    var participants: [CallParticipant] { get }

    /// Whether the local user's camera is active.
    var isLocalCameraEnabled: Bool { get }

    /// Whether the local user's microphone is active.
    var isLocalMicrophoneEnabled: Bool { get }

    /// The identity of the local participant, set after connection.
    var localParticipantID: String? { get }

    /// Human-readable description of the current connection step. Only
    /// non-nil while `state == .connecting`. The UI is expected to hide
    /// transient phases (steps shorter than ~300ms) so the indicator
    /// only surfaces during genuinely slow joins on poor networks.
    var connectingPhase: String? { get }

    /// A monotonically increasing counter that is bumped whenever video tracks change
    /// (publish, unpublish, camera toggle, etc.). SwiftUI views should read this value
    /// to ensure ``NSViewRepresentable`` bridges receive `updateNSView` calls when the
    /// underlying video track becomes available.
    var videoTrackRevision: UInt { get }

    /// Connects to the call using the provided LiveKit server URL and JWT token.
    ///
    /// - Parameters:
    ///   - url: The WebSocket URL of the LiveKit server (e.g. `"wss://livekit.example.com"`).
    ///   - token: A signed JWT granting access to the room.
    func connect(url: String, token: String, sfuServiceURL: String) async throws

    /// Disconnects from the call and cleans up media resources.
    func disconnect() async

    /// Toggles the local camera on or off.
    func toggleCamera() async throws

    /// Toggles the local microphone on or off.
    func toggleMicrophone() async throws

    /// Returns a SwiftUI view that renders the video track of the given participant,
    /// or `nil` if the participant has no active video track or is not found.
    ///
    /// - Parameter participantID: The ``CallParticipant/id`` of the participant to render.
    func makeVideoView(for participantID: String) -> AnyView?

    /// Returns the aspect ratio (width / height) of the participant's currently
    /// publishing video track, or `nil` if no track is available or its
    /// dimensions haven't been negotiated yet. Tile-based UIs use this to
    /// avoid stretching video — each tile can size itself to the source aspect.
    ///
    /// - Parameter participantID: The ``CallParticipant/id`` of the participant.
    func videoAspectRatio(for participantID: String) -> CGFloat?

    /// Whether on-device live captions are currently enabled for remote
    /// participants. When `true`, each subscribed remote audio track is
    /// piped into Apple's `SpeechAnalyzer` and the latest transcription is
    /// surfaced via ``captions``.
    var isCaptionsEnabled: Bool { get }

    /// Latest caption text for each remote participant whose audio is being
    /// transcribed, keyed by ``CallParticipant/id``. Empty when captions are
    /// disabled or no remote has spoken yet. Final captions clear after a
    /// short fade window so the UI doesn't show stale text.
    var captions: [String: String] { get }

    /// Toggles live captions on or off. Off → on attaches a transcriber to
    /// each currently-subscribed remote audio track (and to any subscribed
    /// later); on → off tears them all down and clears ``captions``.
    func setCaptionsEnabled(_ enabled: Bool) async
}
