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
import Foundation
import LiveKit
import os
import RelayInterface
import Speech

/// Type-eraser that lets us hand a non-Sendable `AVAudioPCMBuffer` to
/// `AVAudioConverter.convert`'s `@Sendable` input closure. Safe here
/// because the converter consumes the buffer synchronously inside the call;
/// we never share the box across concurrency domains.
nonisolated private final class _BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Wraps Apple's on-device `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+)
/// behind LiveKit's ``AudioRenderer`` so a single instance can be attached to a
/// `RemoteAudioTrack` and turn its audio into a stream of partial / final
/// captions.
///
/// Lifecycle:
///
/// 1. Create with the participant's ID and a `@Sendable` callback.
/// 2. `start()` — installs the locale model if needed, kicks off the analyzer,
///    and spins up a task draining `transcriber.results` into the callback.
/// 3. Attach to the audio track via `track.add(audioRenderer:)`. Each
///    `render(pcmBuffer:)` is converted to the analyzer's preferred format and
///    yielded into the input stream.
/// 4. `stop()` — cancels the result task, finalizes the analyzer, and tears
///    down the converter.
///
/// All speech recognition is on-device; the model is downloaded via
/// `AssetInventory` on first use and managed by the system from then on.
final class CaptionTranscriber: NSObject, AudioRenderer, @unchecked Sendable {

    /// Stable identifier of the participant whose audio we're transcribing —
    /// used by the callback to route updates back to the correct UI tile.
    let participantId: String

    /// Receives caption updates. `text` is the latest transcription (volatile
    /// or final); `isFinal == true` means the analyzer has committed it.
    private let onUpdate: @Sendable (_ text: String, _ isFinal: Bool) -> Void

    /// Emits a diagnostic event to the call's activity log. Injected by the
    /// owner (`CallViewModel`) so this background/render-thread component never
    /// has to touch the `@MainActor`-isolated `ActivityLog` directly — the
    /// closure does the actor hop. No speech content is ever passed, only
    /// metadata.
    typealias LogEmit = @Sendable (_ severity: ActivityEvent.Severity, _ summary: String, _ detail: String?) -> Void
    private let onLog: LogEmit

    /// The locale used to pick a transcriber. Defaults to `Locale.current` —
    /// captions are *for* the local user, so their preferred locale wins.
    private let locale: Locale

    // Speech components — created in `start()`, torn down in `stop()`.
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    /// Mutable state touched from both the audio render thread and the
    /// owner. Held under an unfair lock so `render(pcmBuffer:)` stays
    /// synchronous and doesn't pay an actor-hop per buffer.
    private struct State {
        var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
        var converter: AVAudioConverter?
        var converterSource: AVAudioFormat?
        var converterTarget: AVAudioFormat?
        var stopped: Bool = false
        // Diagnostic counters — used to log a one-shot "first frame
        // delivered" message and to surface drop reasons. Reset on stop.
        var totalRendered: Int = 0
        var droppedNotReady: Int = 0
        var droppedConversionFailed: Int = 0
        var totalYielded: Int = 0
        var didLogFirstYield: Bool = false
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(
        participantId: String,
        locale: Locale = .current,
        onUpdate: @escaping @Sendable (String, Bool) -> Void,
        onLog: @escaping LogEmit
    ) {
        self.participantId = participantId
        self.locale = locale
        self.onUpdate = onUpdate
        self.onLog = onLog
        super.init()
    }

    /// Installs the locale model if needed, starts the analyzer, and begins
    /// draining results. Errors propagate so the caller can log + skip
    /// transcribing this track.
    func start() async throws {
        // Use the progressive preset — Apple's tuned configuration for
        // streaming live captioning. Layer on `.fastResults` (less LM
        // verification, lower latency) and `.volatileResults` (per-syllable
        // partials so the UI updates continuously instead of in
        // sentence-sized chunks). For live captions, freshness is worth
        // the modest accuracy trade-off; the user gets context from the
        // rolling history.
        var preset = SpeechTranscriber.Preset.progressiveTranscription
        preset.reportingOptions.insert(.volatileResults)
        preset.reportingOptions.insert(.fastResults)
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)

        try await Self.ensureModelInstalled(for: transcriber, onLog: onLog)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        )

        let (input, builder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)

        self.transcriber = transcriber
        self.analyzer = analyzer
        state.withLock {
            $0.inputBuilder = builder
            $0.converterTarget = target
        }

        // Drain results in a long-lived task. AttributedString is converted to
        // plain string before the @Sendable callback to keep the call site
        // free of UI imports.
        let pid = participantId
        let cb = onUpdate
        resultsTask = Task {
            var loggedFirst = false
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if !loggedFirst {
                        loggedFirst = true
                        onLog(.debug, "Caption first result", "Identity: \(pid), chars: \(text.count), isFinal: \(result.isFinal)")
                    }
                    cb(text, result.isFinal)
                }
                onLog(.debug, "Caption results stream ended", "Identity: \(pid)")
            } catch is CancellationError {
                // Expected on stop(); silent.
            } catch {
                onLog(.warning, "Caption results stream failed", "Identity: \(pid). Error: \(error.localizedDescription)")
            }
        }

        let formatDesc = target.map { "\($0.sampleRate)Hz \($0.channelCount)ch" } ?? "nil"
        onLog(.info, "Caption transcriber started", "Identity: \(pid), locale: \(self.locale.identifier), target: \(formatDesc)")
    }

    /// Tears the analyzer down. Safe to call multiple times.
    func stop() async {
        let builder = state.withLock { s -> AsyncStream<AnalyzerInput>.Continuation? in
            guard !s.stopped else { return nil }
            s.stopped = true
            let b = s.inputBuilder
            s.inputBuilder = nil
            s.converter = nil
            s.converterSource = nil
            s.converterTarget = nil
            return b
        }
        builder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        onLog(.info, "Caption transcriber stopped", "Identity: \(self.participantId)")
    }

    // MARK: - AudioRenderer

    /// Called by LiveKit on the audio thread for every PCM buffer that's
    /// about to be played for this remote track. Buffers are post-decryption.
    func render(pcmBuffer: AVAudioPCMBuffer) {
        // Wrap the non-Sendable pcmBuffer in a Sendable box BEFORE entering
        // the lock — `OSAllocatedUnfairLock.withLock`'s body is @Sendable,
        // and the conversion closure inside it is @Sendable too. The box
        // is the only thing safe to capture across both boundaries.
        let inputBox = _BufferBox(pcmBuffer)
        let inputFormat = pcmBuffer.format
        let inputFrameCount = pcmBuffer.frameLength
        let pid = participantId

        // Each render returns a small status report so we can log outside
        // the lock without doing I/O on the audio thread under the lock.
        enum Outcome {
            case notReady
            case conversionFailed(String?)
            case yielded(firstTime: Bool, frames: Int)
        }

        let outcome: Outcome = state.withLock { s in
            s.totalRendered += 1
            guard !s.stopped,
                  let target = s.converterTarget,
                  let builder = s.inputBuilder else {
                s.droppedNotReady += 1
                return .notReady
            }

            // Build / refresh the converter on first buffer or when the
            // upstream format changes. AVAudioConverter is reusable across
            // calls but tied to a single source/target pair.
            if s.converter == nil || s.converterSource != inputFormat {
                s.converter = AVAudioConverter(from: inputFormat, to: target)
                s.converterSource = inputFormat
            }
            guard let converter = s.converter else {
                s.droppedConversionFailed += 1
                return .conversionFailed("no converter")
            }

            // Sample-rate ratio + a little slack for resampler tail.
            let ratio = target.sampleRate / inputFormat.sampleRate
            let cap = AVAudioFrameCount(Double(inputFrameCount) * ratio + 1024)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else {
                s.droppedConversionFailed += 1
                return .conversionFailed("alloc")
            }

            var error: NSError?
            nonisolated(unsafe) var consumed = false
            _ = converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    // .noDataNow — NOT .endOfStream. With .endOfStream the
                    // converter flushes and enters a finished state that
                    // permanently refuses subsequent input, so every render()
                    // after the first returns 0 frames. .noDataNow tells the
                    // converter "this batch is done, but more is coming".
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return inputBox.buffer
            }
            if error != nil || out.frameLength == 0 {
                s.droppedConversionFailed += 1
                return .conversionFailed(error?.localizedDescription ?? "empty out")
            }

            builder.yield(AnalyzerInput(buffer: out))
            s.totalYielded += 1
            let firstTime = !s.didLogFirstYield
            if firstTime { s.didLogFirstYield = true }
            return .yielded(firstTime: firstTime, frames: Int(out.frameLength))
        }

        switch outcome {
        case .notReady:
            // Silent: this is expected for the first ~few frames before
            // start() finishes setting `inputBuilder`.
            break
        case .conversionFailed(let reason):
            onLog(.warning, "Caption conversion failed", "Identity: \(pid). Reason: \(reason ?? "?")")
        case .yielded(let firstTime, let frames):
            if firstTime {
                onLog(.debug, "Caption first audio frame yielded", "Identity: \(pid), frames: \(frames)")
            }
        }
    }

    // MARK: - Asset Management

    /// Installs the locale model for the given transcriber if it isn't already
    /// available. First-time install can take several seconds; subsequent
    /// calls are immediate.
    private static func ensureModelInstalled(for transcriber: SpeechTranscriber, onLog: LogEmit) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onLog(.info, "Downloading captions model", nil)
            try await request.downloadAndInstall()
        }
    }
}
