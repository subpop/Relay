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

import RelayInterface
import SwiftUI

/// Renders a LiveKit audio/video call within a Matrix room.
///
/// When the view model is in the ``CallState/idle`` state, ``CallView`` shows a
/// credential-entry form so the user can supply the LiveKit server URL and JWT token
/// before connecting. While connecting it shows a spinner with a Cancel button.
/// Once connected it shows participant tiles and a media-control bar.
struct CallView: View {
    @State var viewModel: any CallViewModelProtocol
    /// `true` while the parent is fetching LiveKit credentials from the homeserver.
    /// When set, the `.idle` state shows a spinner instead of the manual-entry form.
    var isPreparingCredentials: Bool = false
    var onDismiss: () -> Void

    // Local fields used only while in the .idle (pre-connect) manual-entry form.
    @State private var serverURL: String = ""
    @State private var accessToken: String = ""
    @State private var isJoining: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                switch viewModel.state {
                case .idle:
                    if isPreparingCredentials {
                        preparingView
                    } else {
                        joinForm
                    }

                case .connecting:
                    connectingView

                case .connected:
                    participantsGrid
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    controlBar

                case .disconnected:
                    endedView(
                        title: "Call Ended",
                        systemImage: "phone.down.fill",
                        description: "The call has ended.",
                        isError: false
                    )

                case .failed(let message):
                    endedView(
                        title: "Call Failed",
                        systemImage: "exclamationmark.triangle.fill",
                        description: message,
                        isError: true
                    )
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - Preparing View (fetching credentials from homeserver)

    @ViewBuilder
    private var preparingView: some View {
        Spacer()
        ProgressView("Contacting call server…")
            .progressViewStyle(.circular)
            .controlSize(.large)
            .foregroundStyle(.white)
            .tint(.white)
        Button("Cancel") { onDismiss() }
            .buttonStyle(.bordered)
            .foregroundStyle(.white)
            .padding(.top, 20)
        Spacer()
    }

    // MARK: - Join Form (idle state)

    @ViewBuilder
    private var joinForm: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)

                Text("Join Call")
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                Text("Enter the LiveKit server URL and access token\nprovided by your call server.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Server URL")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    TextField("wss://livekit.example.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    Text("Access Token")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 4)
                    TextField("JWT token", text: $accessToken)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                .frame(maxWidth: 360)

                HStack(spacing: 16) {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.white)

                    Button("Join") {
                        guard !serverURL.isEmpty, !accessToken.isEmpty else { return }
                        Task {
                            isJoining = true
                            try? await viewModel.connect(url: serverURL, token: accessToken)
                            isJoining = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serverURL.isEmpty || accessToken.isEmpty || isJoining)
                }
            }
            .padding(40)

            Spacer()
        }
    }

    // MARK: - Connecting View

    @ViewBuilder
    private var connectingView: some View {
        Spacer()
        ProgressView("Joining call…")
            .progressViewStyle(.circular)
            .controlSize(.large)
            .foregroundStyle(.white)
            .tint(.white)
        Button("Cancel") {
            Task {
                await viewModel.disconnect()
                onDismiss()
            }
        }
        .buttonStyle(.bordered)
        .foregroundStyle(.white)
        .padding(.top, 20)
        Spacer()
    }

    // MARK: - Ended / Failed View

    @ViewBuilder
    private func endedView(title: String, systemImage: String, description: String, isError: Bool) -> some View {
        Spacer()
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .foregroundStyle(.white)
        Button("Dismiss") { onDismiss() }
            .buttonStyle(.borderedProminent)
            .tint(isError ? .red : .accentColor)
            .padding(.top, 12)
        Spacer()
    }

    // MARK: - Participants Grid
    //
    // NOTE: For a richer integration, consider adopting LiveKitComponents
    // (ForEachParticipant / ForEachTrack / VideoTrackView) which handle
    // participant lifecycle, adaptive streaming, and reconnection automatically.
    // See: https://github.com/livekit/components-swift

    @ViewBuilder
    private var participantsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 400), spacing: 8)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(viewModel.participants) { participant in
                    participantTile(participant)
                        .id(participant.id)
                }
                if let localID = viewModel.localParticipantID {
                    localParticipantTile(id: localID)
                        .id(localID)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Participant Tile

    @ViewBuilder
    private func participantTile(_ participant: CallParticipant) -> some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: .darkGray)

            videoContent(for: participant.id)

            if participant.isSpeaking {
                Rectangle()
                    .strokeBorder(.green, lineWidth: 3)
            }

            HStack(spacing: 6) {
                Text(participant.displayName ?? participant.id)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if !participant.isMicrophoneEnabled {
                    Image(systemName: "mic.slash.fill").font(.caption).foregroundStyle(.red)
                }
                if !participant.isCameraEnabled {
                    Image(systemName: "video.slash.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    // MARK: - Local Participant Tile

    @ViewBuilder
    private func localParticipantTile(id: String) -> some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: .darkGray)

            videoContent(for: id)

            HStack(spacing: 6) {
                Text("You").font(.caption).foregroundStyle(.white)
                Spacer()
                if !viewModel.isLocalMicrophoneEnabled {
                    Image(systemName: "mic.slash.fill").font(.caption).foregroundStyle(.red)
                }
                if !viewModel.isLocalCameraEnabled {
                    Image(systemName: "video.slash.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    // MARK: - Control Bar

    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 24) {
            Button {
                Task { try? await viewModel.toggleMicrophone() }
            } label: {
                Image(systemName: viewModel.isLocalMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(viewModel.isLocalMicrophoneEnabled ? Color.white.opacity(0.15) : Color.red.opacity(0.8))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help(viewModel.isLocalMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")

            Button {
                Task { try? await viewModel.toggleCamera() }
            } label: {
                Image(systemName: viewModel.isLocalCameraEnabled ? "video.fill" : "video.slash.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(viewModel.isLocalCameraEnabled ? Color.white.opacity(0.15) : Color.red.opacity(0.8))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help(viewModel.isLocalCameraEnabled ? "Turn off camera" : "Turn on camera")

            Button {
                Task {
                    await viewModel.disconnect()
                    onDismiss()
                }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .background(Color.red)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("End call")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 32)
        .background(.black.opacity(0.7))
    }
}

// MARK: - Video Content

extension CallView {
    /// Returns the LiveKit `SwiftUIVideoView` (via `AnyView`) for the given participant,
    /// or a dark grey placeholder if no video track is available yet.
    ///
    /// > Important: Do **not** apply `.clipShape()` or `.mask()` to the returned
    /// > video view.  `SwiftUIVideoView` renders via Metal and SwiftUI shape
    /// > clipping interferes with the GPU-backed surface, causing visual artefacts.
    @ViewBuilder
    fileprivate func videoContent(for participantID: String) -> some View {
        // Reading videoTrackRevision ensures SwiftUI re-evaluates this
        // when tracks change (publish, subscribe, toggle).
        let _ = viewModel.videoTrackRevision
        if let videoView = viewModel.makeVideoView(for: participantID) {
            videoView
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .darkGray))
        }
    }
}

// MARK: - Previews

#Preview("Join Form") {
    CallView(viewModel: PreviewCallViewModel(), onDismiss: {})
        .frame(width: 640, height: 480)
}

#Preview("Connecting") {
    @Previewable @State var vm = PreviewCallViewModel()
    CallView(viewModel: vm, onDismiss: {})
        .frame(width: 640, height: 480)
        .onAppear { vm.state = .connecting }
}

#Preview("Connected") {
    let vm = PreviewCallViewModel()
    return CallView(viewModel: vm, onDismiss: {})
        .frame(width: 640, height: 480)
        .task {
            try? await vm.connect(url: "wss://preview.example.com", token: "preview-token")
        }
}
