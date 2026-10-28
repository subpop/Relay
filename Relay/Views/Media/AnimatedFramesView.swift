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

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The decoded frame timing of an animated WebP or PNG (APNG).
///
/// `NSImageView.animates` only drives GIFs: AppKit exposes each WebP or APNG
/// frame as a separate image representation. ImageIO does decode the frames
/// and their delays, so playback is driven from here. Frames are decoded on
/// demand to keep long animations out of memory.
struct AnimatedImageFrames {
    private let source: CGImageSource
    private let delays: [TimeInterval]
    private let totalDuration: TimeInterval

    /// Delays below this are treated as unspecified, as browsers do.
    private static let minimumDelay: TimeInterval = 0.02
    private static let defaultDelay: TimeInterval = 0.1

    /// Reads the frames of `data`, or returns nil when it is not a WebP or
    /// PNG with more than one frame. GIFs play through ``AnimatedImageView``.
    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 1,
            let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        else { return nil }
        let delayKeys: (dictionary: CFString, delay: CFString)
        if type == .webP {
            delayKeys = (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime)
        } else if type == .png {
            delayKeys = (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime)
        } else {
            return nil
        }
        self.source = source
        delays = (0..<CGImageSourceGetCount(source)).map { index in
            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let format = properties?[delayKeys.dictionary] as? [CFString: Any]
            let delay = format?[delayKeys.delay] as? TimeInterval
            return if let delay, delay >= Self.minimumDelay { delay } else { Self.defaultDelay }
        }
        totalDuration = delays.reduce(0, +)
    }

    /// The first frame, shown while the animation is paused.
    var firstFrame: CGImage? {
        CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The frame to show at `date`, looping from the reference date.
    func frame(at date: Date) -> CGImage? {
        var elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: totalDuration)
        var index = 0
        while index < delays.count - 1, elapsed >= delays[index] {
            elapsed -= delays[index]
            index += 1
        }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }
}

/// Plays an animated WebP or APNG while `isAnimating`, and shows its first
/// frame otherwise. Sizing is left to the caller.
struct AnimatedFramesView: View {
    let frames: AnimatedImageFrames
    let isAnimating: Bool

    var body: some View {
        SwiftUI.TimelineView(.animation(paused: !isAnimating)) { context in
            if let frame = isAnimating ? frames.frame(at: context.date) : frames.firstFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
            }
        }
    }
}
