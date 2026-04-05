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
import RelayInterface
import SwiftUI

/// Renders an active or connecting LiveKit call within a Matrix room.
///
/// ``CallView`` shows participant tiles with video/audio indicators and a bottom
/// control bar for toggling local media and ending the call. It relies solely on
/// ``CallViewModelProtocol`` — no LiveKit types are referenced here.
struct CallView: View {
    @State var viewModel: any CallViewModelProtocol
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                switch viewModel.state {
                case .idle, .connecting:
                    Spacer()
                    ProgressView("Joining call…")
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .foregroundStyle(.white)
                        .tint(.white)
                    Spacer()

                case .connected:
                    participantsGrid
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    controlBar

                case .disconnected:
                    Spacer()
                    ContentUnavailableView(
                        "Call Ended",
                        systemImage: "phone.down.fill",
                        description: Text("The call has ended.")
                    )
                    .foregroundStyle(.white)
                    Button("Dismiss") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 12)
                    Spacer()

                case .failed(let message):
                    Spacer()
                    ContentUnavailableView(
                        "Call Failed",
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text(message)
                    )
                    .foregroundStyle(.white)
                    Button("Dismiss") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .padding(.top, 12)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - Participants Grid

    @ViewBuilder
    private var participantsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 400), spacing: 8)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(viewModel.participants) { participant in
                    participantTile(participant)
                }
                // Local participant tile
                if let localID = viewModel.localParticipantID {
                    localParticipantTile(id: localID)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Participant Tile

    @ViewBuilder
    private func participantTile(_ participant: CallParticipant) -> some View {
        ZStack(alignment: .bottom) {
            // Video or placeholder background
            VideoViewRepresentable(viewModel: viewModel, participantID: participant.id)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Speaking ring overlay
            if participant.isSpeaking {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.green, lineWidth: 3)
            }

            // Name label + media indicators
            HStack(spacing: 6) {
                Text(participant.displayName ?? participant.id)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if !participant.isMicrophoneEnabled {
                    Image(systemName: "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !participant.isCameraEnabled {
                    Image(systemName: "video.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
            .clipShape(
                .rect(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 10,
                    topTrailingRadius: 0
                )
            )
        }
    }

    // MARK: - Local Participant Tile

    @ViewBuilder
    private func localParticipantTile(id: String) -> some View {
        ZStack(alignment: .bottom) {
            VideoViewRepresentable(viewModel: viewModel, participantID: id)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 6) {
                Text("You")
                    .font(.caption)
                    .foregroundStyle(.white)

                Spacer()

                if !viewModel.isLocalMicrophoneEnabled {
                    Image(systemName: "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !viewModel.isLocalCameraEnabled {
                    Image(systemName: "video.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
            .clipShape(
                .rect(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 10,
                    topTrailingRadius: 0
                )
            )
        }
    }

    // MARK: - Control Bar

    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 24) {
            // Microphone toggle
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

            // Camera toggle
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

            // End call button
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

// MARK: - NSView Bridge for Video

/// An `NSViewRepresentable` that embeds the opaque `NSView` returned by
/// ``CallViewModelProtocol/makeVideoView(for:)``.
///
/// If the view model returns `nil` (participant has no active video track), a dark
/// gray placeholder with the participant's initials is shown instead.
private struct VideoViewRepresentable: NSViewRepresentable {
    let viewModel: any CallViewModelProtocol
    let participantID: String

    func makeNSView(context: Context) -> NSView {
        if let videoView = viewModel.makeVideoView(for: participantID) {
            return videoView
        }
        return makePlaceholder()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Video track updates are managed by the LiveKit VideoView internally.
        // No manual refresh needed here.
    }

    private func makePlaceholder() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.darkGray.cgColor
        view.layer?.cornerRadius = 10
        return view
    }
}

// MARK: - Previews

#Preview("Idle") {
    CallView(viewModel: PreviewCallViewModel(), onDismiss: {})
        .frame(width: 640, height: 480)
}

#Preview("Connected") {
    let vm = PreviewCallViewModel()
    return CallView(viewModel: vm, onDismiss: {})
        .frame(width: 640, height: 480)
        .task {
            try? await vm.connect(url: "wss://preview.example.com", token: "preview-token")
        }
}
