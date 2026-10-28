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
import ImageIO

/// How the `is_animated` image-info flag steers loading and sending.
enum ImageAnimation {
    /// Whether to fetch the original image instead of a server thumbnail.
    ///
    /// Thumbnails are static, so an animation needs its original. A sender's
    /// `true` asks for the original whatever the format; its `false` is
    /// only ever used to skip a large download, never to stop playback of
    /// something already loaded, because the flag shouldn't be trusted. With
    /// no flag, GIFs and WebPs are assumed animated.
    static func loadsOriginal(isAnimated: Bool?, isGIF: Bool, isWebP: Bool) -> Bool {
        isAnimated ?? (isGIF || isWebP)
    }

    /// Whether encoded image data holds more than one frame, or nil when it
    /// can't be read as an image. Senders leave the flag unset in that case.
    static func isAnimated(imageData data: Data) -> Bool? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Data that isn't an image still yields a source, with no frames.
        let frames = CGImageSourceGetCount(source)
        return frames > 0 ? frames > 1 : nil
    }
}
