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

import CoreGraphics
import MatrixKit

extension MediaInfo {
    /// Computes a display size for media content, fitting within the given
    /// maximum dimensions while preserving the original aspect ratio.
    ///
    /// When the media's intrinsic dimensions are unknown, the returned size
    /// uses `maxWidth` and `defaultHeight`.
    ///
    /// - Parameters:
    ///   - maxWidth: The maximum width for the display frame.
    ///   - maxHeight: The maximum height for the display frame.
    ///   - defaultHeight: The fallback height when intrinsic dimensions are unavailable.
    /// - Returns: A size that fits within the constraints.
    func displaySize(
        maxWidth: CGFloat = 280,
        maxHeight: CGFloat = 320,
        defaultHeight: CGFloat = 200
    ) -> CGSize {
        if let w = width, let h = height, w > 0, h > 0 {
            let aspect = CGFloat(w) / CGFloat(h)
            let fitWidth = min(CGFloat(w), maxWidth)
            let fitHeight = fitWidth / aspect
            if fitHeight > maxHeight {
                return CGSize(width: maxHeight * aspect, height: maxHeight)
            }
            return CGSize(width: fitWidth, height: fitHeight)
        }
        return CGSize(width: maxWidth, height: defaultHeight)
    }
}
