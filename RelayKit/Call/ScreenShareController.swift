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

import AVFoundation
import CoreMedia
import Foundation
import LiveKit
import ScreenCaptureKit

/// Owns the native macOS screen-share pipeline and bridges it into LiveKit.
///
/// This is "Path A" from the screen-share design: rather than letting
/// LiveKit's `MacOSScreenCapturer` enumerate and pick sources itself, we
/// drive Apple's `SCContentSharingPicker` directly (so the user gets the
/// same system picker FaceTime uses, plus the menu-bar presenter overlay /
/// stop-sharing control for free), run our own `SCStream`, and feed the
/// captured frames into a LiveKit `BufferCapturer`-backed track. App audio
/// is mixed into the outgoing audio via `AudioManager.shared.mixer`, the
/// same sink LiveKit's own capturer uses.
///
/// LiveKit can't accept the picker's `SCContentFilter` (its capturer
/// resolves filters from internal `SCWindow`/`SCDisplay` objects we can't
/// construct), which is why we own the stream end-to-end.
///
/// Callbacks are delivered on the main actor. The owner (``CallViewModel``)
/// is responsible for publishing/unpublishing the track it receives via
/// ``onTrackReady`` — this controller never touches the `Room`.
final class ScreenShareController: NSObject, @unchecked Sendable {
    /// Delivered once the user picks a source and the capture stream is
    /// live. The owner should publish the track.
    var onTrackReady: (@MainActor (LocalVideoTrack) -> Void)?
    /// Delivered when the user dismissed the picker without choosing.
    var onCancelled: (@MainActor () -> Void)?
    /// Delivered when an active share ended outside the app's toggle —
    /// e.g. the user clicked "Stop Sharing" in the macOS menu bar, or the
    /// stream failed. The owner should unpublish and reset state.
    var onStoppedExternally: (@MainActor (_ reason: String) -> Void)?
    /// Delivered when starting capture failed (permission denied, stream
    /// start error). The owner should surface this to the user.
    var onError: (@MainActor (Error) -> Void)?

    private let captureAppAudio: Bool
    private let videoSampleQueue = DispatchQueue(label: "camera.relay.screenshare.video")
    private let audioSampleQueue = DispatchQueue(label: "camera.relay.screenshare.audio")

    private var stream: SCStream?
    private var track: LocalVideoTrack?
    // Read from the nonisolated sample-handler queue, written once on the
    // main actor in `startCapture` before frames start flowing. The module
    // defaults to main-actor isolation, so this needs `nonisolated(unsafe)`
    // to be reachable from the capture queue; the write-before-frames
    // ordering makes the access safe.
    nonisolated(unsafe) private weak var bufferCapturer: BufferCapturer?

    init(captureAppAudio: Bool) {
        self.captureAppAudio = captureAppAudio
        super.init()
    }

    /// Presents the system screen-share picker. The result arrives via the
    /// `SCContentSharingPickerObserver` callbacks below.
    @MainActor
    func presentPicker() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    /// Stops an active share and tears down the stream. Safe to call when
    /// nothing is active. Does not fire `onStoppedExternally` — the caller
    /// initiated this, so it already knows.
    @MainActor
    func stop() async {
        deactivatePicker()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        track = nil
        bufferCapturer = nil
    }

    @MainActor
    private func deactivatePicker() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        // Only deactivate if no other consumer is using it. We're the only
        // consumer in this app, so it's safe to flip off.
        picker.isActive = false
    }

    // MARK: - Stream setup

    @MainActor
    private func startCapture(with filter: SCContentFilter) async {
        let configuration = SCStreamConfiguration()
        // Capture at the source's native pixel resolution.
        let scale = filter.pointPixelScale
        configuration.width = Int(filter.contentRect.width * CGFloat(scale))
        configuration.height = Int(filter.contentRect.height * CGFloat(scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.capturesAudio = captureAppAudio

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoSampleQueue)
            if captureAppAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSampleQueue)
            }

            // BufferCapturer-backed track. `createBufferTrack` exposes the
            // capturer back to us via `LocalVideoTrack.capturer`, which is
            // how we push frames in `didOutputSampleBuffer`.
            let track = LocalVideoTrack.createBufferTrack(
                source: .screenShareVideo,
                options: BufferCaptureOptions()
            )
            self.track = track
            self.bufferCapturer = track.capturer as? BufferCapturer

            try await stream.startCapture()
            self.stream = stream
            onTrackReady?(track)
        } catch {
            self.stream = nil
            self.track = nil
            self.bufferCapturer = nil
            deactivatePicker()
            onError?(error)
        }
    }

    // MARK: - Audio bridging

    /// Mixes ScreenCaptureKit app audio into the local participant's
    /// outgoing audio. Uses LiveKit's `CMSampleBuffer.toAVAudioPCMBuffer()`
    /// helper — the same conversion its own `MacOSScreenCapturer` uses,
    /// which builds the format via `AVAudioFormat(cmAudioFormatDescription:)`
    /// and so preserves the non-interleaved channel layout SCStream
    /// delivers. Called from the nonisolated audio sample-handler queue.
    nonisolated private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = sampleBuffer.toAVAudioPCMBuffer() else { return }
        AudioManager.shared.mixer.capture(appAudio: pcm)
    }
}

// MARK: - SCContentSharingPickerObserver

extension ScreenShareController: SCContentSharingPickerObserver {
    // `SCContentSharingPickerObserver` is a `@MainActor` protocol, but
    // ScreenCaptureKit delivers these callbacks over XPC on the replayd
    // background queue. Leaving the conformance main-actor-isolated makes
    // the Swift runtime insert an executor precondition that fails the
    // instant a filter is selected. We mark the witnesses `nonisolated`
    // and hop to the main actor ourselves.
    nonisolated func contentSharingPicker(_: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for _: SCStream?) {
        // `SCContentFilter` isn't `Sendable`. We're the sole consumer and
        // hand it straight to the main actor for one-shot use, so the
        // cross-actor move is safe.
        nonisolated(unsafe) let filter = filter
        Task { @MainActor [weak self] in
            await self?.startCapture(with: filter)
        }
    }

    nonisolated func contentSharingPicker(_: SCContentSharingPicker, didCancelFor _: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.deactivatePicker()
            self.onCancelled?()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.deactivatePicker()
            self.onError?(error)
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenShareController: SCStreamDelegate {
    nonisolated func stream(_: SCStream, didStopWithError error: Error) {
        // Fires when the user stops the share from the macOS menu-bar
        // control, or the stream dies. Called on a background queue —
        // hop to main before touching our state or the owner.
        let description = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stream = nil
            self.track = nil
            self.bufferCapturer = nil
            self.deactivatePicker()
            self.onStoppedExternally?(description)
        }
    }
}

// MARK: - SCStreamOutput

extension ScreenShareController: SCStreamOutput {
    // Like the picker observer, `SCStreamOutput` is main-actor-isolated in
    // the SDK, but SCStream delivers sample buffers on the
    // `sampleHandlerQueue` we passed. `nonisolated` drops the executor
    // precondition so frames don't crash the capture queue; everything
    // here is queue-safe (`BufferCapturer.capture` and the audio mixer
    // are both designed to be fed from a capture thread).
    nonisolated func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard sampleBuffer.isValid,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            bufferCapturer?.capture(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer)
        case .microphone:
            // The macOS 26 SDK can deliver the participant's microphone on the
            // screen stream. We don't route it here — their mic is already
            // published as the call's normal LiveKit audio track — so ignore it.
            break
        @unknown default:
            break
        }
    }
}
