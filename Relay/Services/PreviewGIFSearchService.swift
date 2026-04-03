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
import RelayInterface

/// A mock ``GIFSearchServiceProtocol`` for SwiftUI previews.
///
/// Returns a static set of sample results so the GIF picker can be previewed
/// without network access or a GIPHY API key.
final class PreviewGIFSearchService: GIFSearchServiceProtocol {
    func search(query: String, offset: Int, limit: Int) async throws -> [GIFSearchResult] {
        Self.sampleResults
    }

    func trending(offset: Int, limit: Int) async throws -> [GIFSearchResult] {
        Self.sampleResults
    }

    func registerAction(url: URL) async {}

    func downloadGIF(url: URL) async throws -> Data {
        // Return empty data for previews.
        Data()
    }

    // MARK: - Sample Data

    private static func makeSampleResults() -> [GIFSearchResult] {
        let previewURL = URL(string: "https://media.giphy.com/media/preview/200.gif")!
        let originalURL = URL(string: "https://media.giphy.com/media/original/giphy.gif")!
        return (1...12).map { index in
            GIFSearchResult(
                id: "preview-\(index)",
                title: "Sample GIF \(index)",
                previewURL: previewURL,
                previewSize: CGSize(width: 180, height: 200),
                originalURL: originalURL,
                originalSize: CGSize(width: 360, height: 400)
            )
        }
    }

    private static let sampleResults = makeSampleResults()
}
