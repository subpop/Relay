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
import Testing

@testable import Relay

/// How the `is_animated` flag steers loading, and how senders determine it.
@Suite
struct ImageAnimationTests {
    // 8x8 test images: two frames when animated, one when still.
    nonisolated private static let animatedGIF = "R0lGODlhCAAIAPcfMQAAAAAAVQAAqgAA/wAkAAAkVQAkqgAk/wBIAABIVQBIqgBI/wBsAABsVQBsqgBs/wCQAACQVQCQqgCQ/wC0AAC0VQC0qgC0/wDYAADYVQDYqgDY/wD8AAD8VQD8qgD8/yQAACQAVSQAqiQA/yQkACQkVSQkqiQk/yRIACRIVSRIqiRI/yRsACRsVSRsqiRs/ySQACSQVSSQqiSQ/yS0ACS0VSS0qiS0/yTYACTYVSTYqiTY/yT8ACT8VST8qiT8/0gAAEgAVUgAqkgA/0gkAEgkVUgkqkgk/0hIAEhIVUhIqkhI/0hsAEhsVUhsqkhs/0iQAEiQVUiQqkiQ/0i0AEi0VUi0qki0/0jYAEjYVUjYqkjY/0j8AEj8VUj8qkj8/2wAAGwAVWwAqmwA/2wkAGwkVWwkqmwk/2xIAGxIVWxIqmxI/2xsAGxsVWxsqmxs/2yQAGyQVWyQqmyQ/2y0AGy0VWy0qmy0/2zYAGzYVWzYqmzY/2z8AGz8VWz8qmz8/5AAAJAAVZAAqpAA/5AkAJAkVZAkqpAk/5BIAJBIVZBIqpBI/5BsAJBsVZBsqpBs/5CQAJCQVZCQqpCQ/5C0AJC0VZC0qpC0/5DYAJDYVZDYqpDY/5D8AJD8VZD8qpD8/7QAALQAVbQAqrQA/7QkALQkVbQkqrQk/7RIALRIVbRIqrRI/7RsALRsVbRsqrRs/7SQALSQVbSQqrSQ/7S0ALS0VbS0qrS0/7TYALTYVbTYqrTY/7T8ALT8VbT8qrT8/9gAANgAVdgAqtgA/9gkANgkVdgkqtgk/9hIANhIVdhIqthI/9hsANhsVdhsqths/9iQANiQVdiQqtiQ/9i0ANi0Vdi0qti0/9jYANjYVdjYqtjY/9j8ANj8Vdj8qtj8//wAAPwAVfwAqvwA//wkAPwkVfwkqvwk//xIAPxIVfxIqvxI//xsAPxsVfxsqvxs//yQAPyQVfyQqvyQ//y0APy0Vfy0qvy0//zYAPzYVfzYqvzY//z8APz8Vfz8qvz8/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQEFAAfACwAAAAACAAIAAAINQABgOPAb8C4D/8EjhvAjwO4hB8WNgQHAEBEhg4rXpyoUWJGcPg4dfiwYJA4cPT4cCA5ZlxAACH5BAUUAAAALAAABgAIAAIAAAgTAMnx4wJgw4BhAARy8WBwlLiAAAA7"
    nonisolated private static let animatedWebP = "UklGRjYBAABXRUJQVlA4WAoAAAACAAAABwAABwAAQU5JTQYAAAD/////AABBTk1GnAAAAAAAAAAAAAcAAAcAAMgAAAJWUDgghAAAAJACAJ0BKggACAACADQlsAJ0MoA6QApUpcrXQxZgAP7xvH4Mzb5PUl9i8SYs9LsFD/mLNfTXj+3K+k/E8uCJ8vCnQEvw9SdXs9lPAjJ3odwBPlSj/8dnY7CkJkH77/lRVtH//KBw/5UP9ORJax/E7974hFQGF5P97z3xQ9bdz/mhn0gAAEFOTUZmAAAAAAAAAwAABwAAAQAAyAAAAFZQOCBOAAAAdAIAnQEqCAACAAAANCWoAnSSAPIAyQAFDu5OuAD+4l4n4H9b/ksNvr34AAj/5QbD/5UP/7Jn/lBsP/lQ/eXaXM5P/+4E+2czk/1IAAAA"
    nonisolated private static let animatedAPNG = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAACXBIWXMAAAABAAAAAQBPJcTWAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAAIAAAACAAAAAAAAAAAAAEABQAA+RL9XwAAAE1JREFUeJytjtEJgEAMQ/PAwRxNN9PJatoKHoL4c/lI0hBKkBRhwlRqM96LboQTqk1rH13ApoIXgOfDFyYUcqlOtJVZPTBStOdGHf8fLis8GRr9yJCPAAAAGmZjVEwAAAABAAAACAAAAAIAAAAAAAAABgABAAUAAGa+X6cAAAAxZmRBVAAAAAJ4nGP8b8zwn+EAA4MvDwPDFoZiBoazPQwMDgwMm78wMPgw9DKwMBAAALV8CJCnLAp0AAAAAElFTkSuQmCC"
    nonisolated private static let stillGIF = "R0lGODlhCAAIAPcfMQAAAAAAVQAAqgAA/wAkAAAkVQAkqgAk/wBIAABIVQBIqgBI/wBsAABsVQBsqgBs/wCQAACQVQCQqgCQ/wC0AAC0VQC0qgC0/wDYAADYVQDYqgDY/wD8AAD8VQD8qgD8/yQAACQAVSQAqiQA/yQkACQkVSQkqiQk/yRIACRIVSRIqiRI/yRsACRsVSRsqiRs/ySQACSQVSSQqiSQ/yS0ACS0VSS0qiS0/yTYACTYVSTYqiTY/yT8ACT8VST8qiT8/0gAAEgAVUgAqkgA/0gkAEgkVUgkqkgk/0hIAEhIVUhIqkhI/0hsAEhsVUhsqkhs/0iQAEiQVUiQqkiQ/0i0AEi0VUi0qki0/0jYAEjYVUjYqkjY/0j8AEj8VUj8qkj8/2wAAGwAVWwAqmwA/2wkAGwkVWwkqmwk/2xIAGxIVWxIqmxI/2xsAGxsVWxsqmxs/2yQAGyQVWyQqmyQ/2y0AGy0VWy0qmy0/2zYAGzYVWzYqmzY/2z8AGz8VWz8qmz8/5AAAJAAVZAAqpAA/5AkAJAkVZAkqpAk/5BIAJBIVZBIqpBI/5BsAJBsVZBsqpBs/5CQAJCQVZCQqpCQ/5C0AJC0VZC0qpC0/5DYAJDYVZDYqpDY/5D8AJD8VZD8qpD8/7QAALQAVbQAqrQA/7QkALQkVbQkqrQk/7RIALRIVbRIqrRI/7RsALRsVbRsqrRs/7SQALSQVbSQqrSQ/7S0ALS0VbS0qrS0/7TYALTYVbTYqrTY/7T8ALT8VbT8qrT8/9gAANgAVdgAqtgA/9gkANgkVdgkqtgk/9hIANhIVdhIqthI/9hsANhsVdhsqths/9iQANiQVdiQqtiQ/9i0ANi0Vdi0qti0/9jYANjYVdjYqtjY/9j8ANj8Vdj8qtj8//wAAPwAVfwAqvwA//wkAPwkVfwkqvwk//xIAPxIVfxIqvxI//xsAPxsVfxsqvxs//yQAPyQVfyQqvyQ//y0APy0Vfy0qvy0//zYAPzYVfzYqvzY//z8APz8Vfz8qvz8/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQEZAAfACwAAAAACAAIAAAINQABgOPAb8C4D/8EjhvAjwO4hB8WNgQHAEBEhg4rXpyoUWJGcPg4dfiwYJA4cPT4cCA5ZlxAADs="
    nonisolated private static let stillWebP = "UklGRpAAAABXRUJQVlA4IIQAAACQAgCdASoIAAgAAgA0JbACdDKAOkAKVKXK10MWYAD+8bx+DM2+T1JfYvEmLPS7BQ/5izX014/tyvpPxPLgifLwp0BL8PUnV7PZTwIyd6HcAT5Uo//HZ2OwpCZB++/5UVbR//ygcP+VD/TkSWsfxO/e+IRUBheT/e898UPW3c/5oZ9IAAA="
    nonisolated private static let stillPNG = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAACXBIWXMAAAABAAAAAQBPJcTWAAAATUlEQVR4nK2O0QmAQAxD88DBHE0308lq2goegvhz+UjSEEqQFGHCVGoz3otuhBOqTWsfXcCmgheA58MXJhRyqU60lVk9MFK050Yd/x8uKzwZGv3IkI8AAAAASUVORK5CYII="

    private static func data(_ base64: String) -> Data {
        Data(base64Encoded: base64) ?? Data()
    }

    struct LoadCase: Sendable {
        var isAnimated: Bool?
        var isGIF: Bool
        var isWebP: Bool
        var loadsOriginal: Bool
    }

    nonisolated static let loadCases: [LoadCase] = [
        // The flag decides when it is present.
        LoadCase(isAnimated: true, isGIF: false, isWebP: false, loadsOriginal: true),
        LoadCase(isAnimated: true, isGIF: true, isWebP: false, loadsOriginal: true),
        LoadCase(isAnimated: false, isGIF: true, isWebP: false, loadsOriginal: false),
        LoadCase(isAnimated: false, isGIF: false, isWebP: true, loadsOriginal: false),
        // Without it, GIFs and WebPs are assumed animated.
        LoadCase(isAnimated: nil, isGIF: true, isWebP: false, loadsOriginal: true),
        LoadCase(isAnimated: nil, isGIF: false, isWebP: true, loadsOriginal: true),
        LoadCase(isAnimated: nil, isGIF: false, isWebP: false, loadsOriginal: false),
    ]

    @Test(arguments: loadCases)
    func choosesBetweenOriginalAndThumbnail(_ row: LoadCase) {
        #expect(
            ImageAnimation.loadsOriginal(
                isAnimated: row.isAnimated, isGIF: row.isGIF, isWebP: row.isWebP)
                == row.loadsOriginal)
    }

    struct DetectCase: Sendable {
        var id: String
        var base64: String
        var expected: Bool?
    }

    nonisolated static let detectCases: [DetectCase] = [
        DetectCase(id: "animated GIF", base64: animatedGIF, expected: true),
        DetectCase(id: "animated WebP", base64: animatedWebP, expected: true),
        DetectCase(id: "animated PNG", base64: animatedAPNG, expected: true),
        DetectCase(id: "still GIF", base64: stillGIF, expected: false),
        DetectCase(id: "still WebP", base64: stillWebP, expected: false),
        DetectCase(id: "still PNG", base64: stillPNG, expected: false),
        DetectCase(id: "not an image", base64: Data("hello".utf8).base64EncodedString(), expected: nil),
    ]

    @Test(arguments: detectCases)
    func sendersDetectAnimation(_ row: DetectCase) {
        #expect(ImageAnimation.isAnimated(imageData: Self.data(row.base64)) == row.expected)
    }

    @Test func playsAnimatedWebPAndPNG() {
        #expect(AnimatedImageFrames(data: Self.data(Self.animatedWebP)) != nil)
        #expect(AnimatedImageFrames(data: Self.data(Self.animatedAPNG)) != nil)
    }

    @Test func leavesGIFsAndStillsToOtherPaths() {
        // GIFs play through AnimatedImageView; stills have nothing to play.
        #expect(AnimatedImageFrames(data: Self.data(Self.animatedGIF)) == nil)
        #expect(AnimatedImageFrames(data: Self.data(Self.stillWebP)) == nil)
        #expect(AnimatedImageFrames(data: Self.data(Self.stillPNG)) == nil)
        #expect(AnimatedImageFrames(data: Data("hello".utf8)) == nil)
    }
}
