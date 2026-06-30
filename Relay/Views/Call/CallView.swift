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

// MARK: - Caption Helpers

/// Word-aware wrapping for closed-caption text. Greedy fills lines up to
/// `lineLength` characters, breaking only on whitespace; if a single word
/// exceeds `lineLength` it hard-breaks (rare for English speech, common
/// for URLs). Keeps only the last `maxLines` lines so the most recent
/// words always survive.
///
/// Defaults follow Netflix's Timed Text Style Guide for English subtitles:
/// **42 characters per line, max 2 lines visible**. Source:
/// <https://partnerhelp.netflixstudios.com/hc/en-us/articles/360051554394>
fileprivate func wrapForCaptions(_ text: String, lineLength: Int = 42, maxLines: Int = 2) -> String {
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return "" }

    var lines: [String] = []
    var current = ""

    func push(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { lines.append(trimmed) }
    }

    for word in words {
        // Hard-break a word that's individually longer than the line.
        if word.count > lineLength {
            if !current.isEmpty { push(current); current = "" }
            var remaining = Substring(word)
            while remaining.count > lineLength {
                push(String(remaining.prefix(lineLength)))
                remaining = remaining.dropFirst(lineLength)
            }
            current = String(remaining)
            continue
        }

        let candidate = current.isEmpty ? word : current + " " + word
        if candidate.count > lineLength {
            push(current)
            current = word
        } else {
            current = candidate
        }
    }
    push(current)

    if lines.count > maxLines {
        lines = Array(lines.suffix(maxLines))
    }
    return lines.joined(separator: "\n")
}

/// CC-styled caption rectangle used by both the 1:1 layout and the group
/// `ParticipantTile`. White on near-opaque black with a hairline edge and
/// a tight glyph shadow — readable against any video frame.
///
/// Renders each visible line as a separate `Text` view in a VStack:
///
/// - Stable (committed) lines are identified by their content. They use
///   asymmetric move-edge transitions so older lines slide off the top
///   and new lines slide in from the bottom.
/// - The bottom (in-progress) line uses a constant id `captionCurrentLine`
///   so its character-level revisions are recognised as content changes
///   on the same view rather than an insert/remove pair.
/// - `clipShape` cuts the move animations to the rounded background so
///   they look like content scrolling inside the caption box.
///
/// The box hugs its widest visible line — a `frame(maxWidth: 540)` caps
/// the upper bound but the rect shrinks for shorter content because no
/// child claims `.infinity` width.
fileprivate func captionStrip(_ text: String) -> some View {
    let allLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Netflix style: max 2 visible lines. Older content rolls off the top.
    let visibleLines = Array(allLines.suffix(2))
    let stableLines = Array(visibleLines.dropLast())
    let currentLine = visibleLines.last

    // No transitions, no animations — captions roll up by simply
    // updating in place. Any fade or move on a fast-changing live caption
    // reads as visual noise; instant updates are calmer.
    return VStack(spacing: 2) {
        ForEach(stableLines, id: \.self) { line in
            captionLineText(line)
        }
        if let currentLine, !currentLine.isEmpty {
            captionLineText(currentLine)
                .id("captionCurrentLine")
        }
    }
    .transaction { $0.animation = nil }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
        Color.black.opacity(0.85),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
    )
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .frame(maxWidth: 540)
    .fixedSize(horizontal: false, vertical: true)
}

/// One styled caption line. `.lineLimit(1)` is safe because
/// `wrapForCaptions` already breaks long text on word boundaries; this
/// also lets the VStack hug its widest line for a snug box width.
@ViewBuilder
fileprivate func captionLineText(_ text: String) -> some View {
    Text(text)
        .font(.system(.title3, design: .default, weight: .semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .shadow(color: .black.opacity(0.9), radius: 1)
}

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
    /// Connecting-phase label that has stuck around long enough to be
    /// worth showing the user. Updated from
    /// ``CallViewModelProtocol/connectingPhase`` with a ~300 ms reveal
    /// delay so brief phases on a fast network never flash on screen.
    @State private var visibleConnectingPhase: String?
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
                // Clean ending — close the window immediately. No overlay,
                // no "Dismiss" button. Background cleanup (leave event,
                // LiveKit teardown) continues in disconnect()'s task.
                Color.clear
                    .task { onDismiss() }

            case .failed(let message):
                // Errors still show the overlay so the user can read what
                // went wrong before dismissing.
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
            // Background gradient gives tiles something nicer to float on
            // than pure black; keeps the FaceTime-on-Mac feel.
            LinearGradient(
                colors: [Color(white: 0.08), Color(white: 0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 1 remote → primary video fills.
            // 2+ remotes → polished tile grid of remotes only.
            if viewModel.participants.count >= 2 {
                remoteTilesGrid
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 96)   // leave room for control bar + PiP
            } else {
                primaryVideo
                    .ignoresSafeArea()

                // Participant name at top (1:1 only — tiles label themselves)
                VStack {
                    participantNameBar
                    Spacer()
                }

                // Captions for the primary remote, pinned above the control
                // bar so they don't crowd the PiP. Same CC styling as tiles.
                if let firstRemote = viewModel.participants.first,
                   let raw = viewModel.captions[firstRemote.id]?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    VStack {
                        Spacer()
                        captionStrip(wrapForCaptions(raw))
                            .padding(.bottom, 92)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }

            // Self-view PiP — always present, always bottom-right.
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

    // MARK: - Remote Tiles Grid (2+ remotes)

    /// Polished grid of every remote participant. The local view always
    /// stays in the PiP overlay; remotes tile across the main area.
    @ViewBuilder
    private var remoteTilesGrid: some View {
        GeometryReader { geo in
            let remotes = viewModel.participants
            let layout = Self.gridLayout(count: remotes.count, in: geo.size)
            VStack(spacing: 8) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<layout.cols, id: \.self) { col in
                            let idx = row * layout.cols + col
                            if idx < remotes.count {
                                ParticipantTile(
                                    viewModel: viewModel,
                                    participant: remotes[idx]
                                )
                                .id(remotes[idx].id)
                            } else {
                                Color.clear
                            }
                        }
                    }
                }
            }
        }
    }

    /// Picks rows×cols for `count` tiles given the available size.
    /// Mirrors FaceTime-on-Mac's preferences: 2 side-by-side when wide,
    /// 2x2 for 3–4, 2x3/3x2 for 5–6, 3x3 for 7–9.
    private static func gridLayout(count: Int, in size: CGSize) -> (rows: Int, cols: Int) {
        guard count > 0 else { return (1, 1) }
        let isLandscape = size.width >= size.height
        switch count {
        case 1: return (1, 1)
        case 2: return isLandscape ? (1, 2) : (2, 1)
        case 3, 4: return (2, 2)
        case 5, 6: return isLandscape ? (2, 3) : (3, 2)
        case 7, 8, 9: return (3, 3)
        default:
            let cols = Int(ceil(Double(count).squareRoot()))
            let rows = Int(ceil(Double(count) / Double(cols)))
            return (rows, cols)
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

            // Live captions toggle (on-device speech-to-text via SpeechAnalyzer)
            controlButton(
                icon: viewModel.isCaptionsEnabled ? "captions.bubble.fill" : "captions.bubble",
                isActive: viewModel.isCaptionsEnabled,
                help: viewModel.isCaptionsEnabled ? "Hide Captions" : "Show Captions"
            ) {
                let next = !viewModel.isCaptionsEnabled
                Task { await viewModel.setCaptionsEnabled(next) }
            }

            // End call
            Button {
                // Disconnect — the .disconnected case in `body` calls
                // onDismiss() immediately so the window closes.
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
            // Step indicator — only appears once a phase has been the
            // current phase for ~300 ms. Hidden on fast networks.
            if let visibleConnectingPhase {
                Text(visibleConnectingPhase)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .transition(.opacity)
            }
            Button("Cancel") {
                Task { await viewModel.disconnect() }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.white)
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: visibleConnectingPhase)
        .onChange(of: viewModel.connectingPhase, initial: true) { _, newPhase in
            scheduleConnectingPhaseReveal(newPhase)
        }
    }

    /// Reveals `phase` as the visible connecting-phase label after a
    /// short delay (~300 ms). If `connectingPhase` changes again before
    /// the delay fires, the previous phase is never shown — so brief
    /// steps on a fast network don't flash on screen.
    private func scheduleConnectingPhaseReveal(_ phase: String?) {
        guard let phase else {
            visibleConnectingPhase = nil
            return
        }
        // Already showing it — nothing to do.
        if visibleConnectingPhase == phase { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            // Confirm the view model is still on the same phase before
            // committing it to the visible state.
            if viewModel.connectingPhase == phase {
                visibleConnectingPhase = phase
            }
        }
    }

    // MARK: - Failed Overlay
    //
    // Clean endings auto-close via `.disconnected` in `body`. This overlay
    // is only used for failures so the user sees the error before dismissing.

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

// MARK: - Participant Tile

/// A single tile in the remote-participants grid. Video (cropped to fill)
/// inside a rounded rect with a soft shadow, a name pill bottom-left, and
/// a faint outer glow when the participant is speaking. Mirrors the
/// FaceTime-on-Mac aesthetic: clean cards, no hard borders.
private struct ParticipantTile: View {
    let viewModel: any CallViewModelProtocol
    let participant: CallParticipant

    private static let cornerRadius: CGFloat = 14
    /// Aspect used for camera-off tiles or before the first frame arrives.
    private static let placeholderAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        // Re-evaluate when video tracks change so we pick up the real
        // dimensions after the first frame (RoomDelegate bumps
        // videoTrackRevision on streamState transitions).
        let _ = viewModel.videoTrackRevision
        let aspect: CGFloat = {
            if participant.isCameraEnabled,
               let live = viewModel.videoAspectRatio(for: participant.id) {
                return live
            }
            return Self.placeholderAspect
        }()

        ZStack(alignment: .bottomLeading) {
            // Card background — neutral so video looks at home.
            shape.fill(
                LinearGradient(
                    colors: [Color(white: 0.18), Color(white: 0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            if participant.isCameraEnabled {
                VideoRendererView(viewModel: viewModel, participantID: participant.id) {
                    placeholder
                }
                .clipShape(shape)
            } else {
                placeholder
            }

            nameLabel
                .padding(10)

            // Live caption strip — only shown when captions are enabled and
            // this participant has recent transcribed text. Sits above the
            // name pill, centered horizontally. Uses the same shared
            // CC-styled helper as the 1:1 layout.
            if let raw = viewModel.captions[participant.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                captionStrip(wrapForCaptions(raw))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 44)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        // Tile sizes itself to the source video aspect, centered in the
        // grid cell. Surrounding cell area is transparent so the
        // background gradient shows through (no harsh letterbox).
        // Modifier order matters: shadow + overlay must apply to the
        // aspect-fitted shape, then the outer frame centers it in the cell.
        .aspectRatio(aspect, contentMode: .fit)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .overlay(speakingGlow.allowsHitTesting(false))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Subviews

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.35))
            Text(Self.displayName(for: participant))
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var nameLabel: some View {
        // Always show mic state next to the name. Filled mic icon when on,
        // slashed (red-tinted) when muted — mirrors FaceTime / Zoom badges.
        // Solid dark capsule for guaranteed contrast over any video frame —
        // .ultraThinMaterial blends into bright frames and the name vanishes.
        HStack(spacing: 6) {
            Image(systemName: participant.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(participant.isMicrophoneEnabled ? .white : .red)
            Text(Self.displayName(for: participant))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
    }

    /// Pulls a friendly name out of the participant: `displayName` if the
    /// SFU/JWT supplied one, otherwise the localpart of the Matrix user ID
    /// (`@andrew:matrix.example.com:DEVICE` → `andrew`). Falls back to the
    /// raw id if neither pattern matches.
    static func displayName(for p: CallParticipant) -> String {
        if let dn = p.displayName, !dn.isEmpty { return dn }
        let id = p.id
        // LiveKit identity layout used by Element Call:
        // `@<localpart>:<server>:<deviceId>` — strip server + device.
        if id.hasPrefix("@") {
            let body = id.dropFirst()
            if let colon = body.firstIndex(of: ":") {
                let localpart = body[..<colon]
                if !localpart.isEmpty { return String(localpart) }
            }
        }
        return id
    }

    @ViewBuilder
    private var speakingGlow: some View {
        // Outer soft ring + a quiet inner highlight, only when speaking.
        // Both compose with the existing card shape, no hard border.
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if participant.isSpeaking {
            shape
                .stroke(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                .shadow(color: .accentColor.opacity(0.55), radius: 10)
                .shadow(color: .accentColor.opacity(0.35), radius: 22)
        } else {
            shape.stroke(Color.white.opacity(0.04), lineWidth: 0.5)
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
