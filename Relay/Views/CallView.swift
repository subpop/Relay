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

/// Renders a LiveKit audio/video call with a FaceTime-inspired design.
///
/// The call opens in its own borderless window (`.windowStyle(.plain)`).
/// When connected, the remote participant's video fills the window with
/// a small self-view PiP overlay and a translucent floating control bar.
struct CallView: View {
    // `let` — not `@State`. The view model is a reference-typed
    // `@Observable` class owned by `CallManager`; wrapping it in `@State`
    // caused SwiftUI's `StoredLocationBase` to reinitialise the storage on
    // every parent re-render of `CallWindowView`, which surfaces as
    // recursive `StoredLocationBase.beginUpdate` calls during the layout
    // transaction and eventually the "more Update Constraints in Window
    // passes than there are views" fault.
    let viewModel: any CallViewModelProtocol
    var isPreparingCredentials: Bool = false
    var onDismiss: () -> Void

    @State private var serverURL: String = ""
    @State private var accessToken: String = ""
    @State private var isJoining: Bool = false
    // NOTE: The earlier implementation auto-hid the control bar after a
    // timeout using a `controlsVisible` @State + `.animation(.easeInOut(..),
    // value: controlsVisible)` on the control bar's opacity, plus a
    // `.onHover` toggle. That produced the "more Update Constraints in
    // Window passes than there are views" crash: the implicit animation
    // pushed the AppKit `NSAnimationContext.runAnimationGroup` path which
    // invalidated `StoredLocationBase` during an already-running layout
    // pass on the hosting window. The control bar is now always visible.

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
                connectedView

            case .disconnected:
                endedOverlay(
                    title: "Call Ended",
                    systemImage: "phone.down.fill",
                    isError: false
                )

            case .failed(let message):
                endedOverlay(
                    title: "Call Failed",
                    systemImage: "exclamationmark.triangle.fill",
                    isError: true,
                    detail: message
                )
            }
        }
        .frame(minWidth: 320, minHeight: 480)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Connected View (FaceTime-style)

    @ViewBuilder
    private var connectedView: some View {
        ZStack {
            // Primary video: first remote participant fills the window
            primaryVideo
                .ignoresSafeArea()

            // Self-view PiP in bottom-right corner
            if let localID = viewModel.localParticipantID {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        selfViewPiP(id: localID)
                    }
                }
                .padding(12)
                .padding(.bottom, 72)
            }

            // Participant name at top
            VStack {
                participantNameBar
                Spacer()
            }

            // Floating control bar at bottom (always visible).
            VStack {
                Spacer()
                controlBar
            }
            .padding(.bottom, 16)
        }
        // Disable ALL implicit animations within the connected view subtree.
        //
        // Removing the `.animation(...)` modifier on `controlBar` was not
        // enough to stop the "more Update Constraints in Window passes than
        // there are views" crash — SwiftUI still wraps structural changes
        // (`if let firstRemote = ...`, `if let localID = ...`,
        // `if viewModel.isLocalCameraEnabled`, `if first.isSpeaking`) in
        // implicit transition animations during the connect sequence. Each
        // of those animations runs through `NSAnimationContext.runAnimationGroup`
        // inside `NSHostingView.layout`, writing back into the SwiftUI graph
        // and queueing another constraint pass on the same frame — eventually
        // exceeding the view-count budget and tripping the AppKit fault.
        //
        // `.transaction { $0.animation = nil }` strips the animation off
        // every transaction propagated through this subtree, so structural
        // changes happen instantly with no animator running during layout.
        .transaction { $0.animation = nil }
    }

    // MARK: - Primary Video

    @ViewBuilder
    private var primaryVideo: some View {
        if let firstRemote = viewModel.participants.first {
            VideoRendererView(viewModel: viewModel, participantID: firstRemote.id) {
                participantPlaceholder(firstRemote)
            }
            .id(firstRemote.id)
        } else {
            // No remote participants yet — waiting
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Waiting for others to join…")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: - Self-View PiP

    @ViewBuilder
    private func selfViewPiP(id: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .darkGray))

            if viewModel.isLocalCameraEnabled {
                VideoRendererView(viewModel: viewModel, participantID: id) {
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .id(id)
            } else {
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 120, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
    }

    // MARK: - Participant Name Bar

    @ViewBuilder
    private var participantNameBar: some View {
        if let first = viewModel.participants.first {
            HStack {
                if first.isSpeaking {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Text(first.displayName ?? first.id)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial.opacity(0.8), in: Capsule())
            .padding(.top, 12)
        }
    }

    // MARK: - Control Bar

    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 20) {
            // Microphone toggle
            controlButton(
                icon: viewModel.isLocalMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                isActive: viewModel.isLocalMicrophoneEnabled,
                help: viewModel.isLocalMicrophoneEnabled ? "Mute" : "Unmute"
            ) {
                Task { try? await viewModel.toggleMicrophone() }
            }

            // Camera toggle
            controlButton(
                icon: viewModel.isLocalCameraEnabled ? "video.fill" : "video.slash.fill",
                isActive: viewModel.isLocalCameraEnabled,
                help: viewModel.isLocalCameraEnabled ? "Camera Off" : "Camera On"
            ) {
                Task { try? await viewModel.toggleCamera() }
            }

            // End call
            Button {
                // Only disconnect — the endedOverlay auto-dismiss
                // will call onDismiss() after a brief delay.
                Task { await viewModel.disconnect() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .help("End Call")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private func controlButton(icon: String, isActive: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    isActive ? Color.white.opacity(0.15) : Color.red.opacity(0.8),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Participant Placeholder

    @ViewBuilder
    private func participantPlaceholder(_ participant: CallParticipant) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.3))
            Text(participant.displayName ?? participant.id)
                .font(.title2.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Preparing View

    @ViewBuilder
    private var preparingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Contacting call server…")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            Button("Cancel") { onDismiss() }
                .buttonStyle(.bordered)
                .foregroundStyle(.white)
            Spacer()
        }
    }

    // MARK: - Connecting View

    @ViewBuilder
    private var connectingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Joining call…")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            Button("Cancel") {
                Task { await viewModel.disconnect() }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.white)
            Spacer()
        }
    }

    // MARK: - Ended/Failed Overlay

    @ViewBuilder
    private func endedOverlay(title: String, systemImage: String, isError: Bool, detail: String? = nil) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(isError ? .red : .white.opacity(0.6))
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("Dismiss") { onDismiss() }
                .buttonStyle(.borderedProminent)
                .tint(isError ? .red : .accentColor)
                .padding(.top, 4)
            Spacer()
        }
        .task {
            // Auto-dismiss after a few seconds for clean endings.
            if !isError {
                try? await Task.sleep(for: .seconds(2))
                onDismiss()
            }
        }
    }

    // MARK: - Join Form (manual entry fallback)

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

                Text("Enter the LiveKit server URL and access token.")
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
                .frame(maxWidth: 320)

                HStack(spacing: 16) {
                    Button("Cancel") { onDismiss() }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.white)

                    Button("Join") {
                        guard !serverURL.isEmpty, !accessToken.isEmpty else { return }
                        Task {
                            isJoining = true
                            try? await viewModel.connect(url: serverURL, token: accessToken, sfuServiceURL: "")
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
}

// MARK: - Video Renderer

/// Isolates video-track observation into its own SwiftUI view so that
/// `videoTrackRevision` changes only invalidate THIS subtree rather than
/// the entire ``CallView`` hierarchy.
///
/// Previously `primaryVideo` and `selfViewPiP` both read
/// `viewModel.videoTrackRevision` directly in their view bodies, which
/// registered dependencies on the whole containing ZStack. Each track
/// update (camera publish, subscribe, etc.) then re-laid-out every
/// sibling view — and because the rendered video is an `NSViewRepresentable`
/// wrapping an AppKit `VideoView`, that triggered recursive
/// `setNeedsUpdateConstraints` calls on the hosting window, producing the
/// "more Update Constraints in Window passes than there are views" hang.
///
/// The `.id(participantID)` modifier on each usage site gives SwiftUI a
/// stable identity key so the renderer is reused across parent re-renders
/// instead of being torn down and recreated.
private struct VideoRendererView<Placeholder: View>: View {
    let viewModel: any CallViewModelProtocol
    let participantID: String
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        // Reading videoTrackRevision here registers observation *only* on
        // this subtree — it is not read in any enclosing view.
        let _ = viewModel.videoTrackRevision
        if let videoView = viewModel.makeVideoView(for: participantID) {
            videoView
        } else {
            placeholder()
        }
    }
}

// MARK: - Previews

#Preview("Preparing") {
    CallView(viewModel: PreviewCallViewModel(), isPreparingCredentials: true, onDismiss: {})
        .frame(width: 360, height: 540)
}

#Preview("Connected") {
    let vm = PreviewCallViewModel()
    return CallView(viewModel: vm, onDismiss: {})
        .frame(width: 360, height: 540)
        .task {
            try? await vm.connect(url: "wss://preview.example.com", token: "preview-token", sfuServiceURL: "")
        }
}
