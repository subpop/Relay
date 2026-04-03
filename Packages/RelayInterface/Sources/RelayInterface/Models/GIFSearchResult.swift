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

/// A single result from a GIF search, provider-agnostic.
///
/// ``GIFSearchResult`` contains the URLs and dimensions needed to preview a GIF
/// in a picker grid and to download the full-resolution version for sending.
/// It also carries optional analytics URLs that the provider may require to be
/// fired on view, click, and send events.
public struct GIFSearchResult: Sendable, Identifiable, Hashable {
    /// The provider's unique identifier for this GIF.
    public let id: String

    /// A human-readable title for this GIF.
    public let title: String

    /// URL for a fixed-height (200px) rendition suitable for grid previews.
    public let previewURL: URL

    /// The pixel dimensions of the preview rendition.
    public let previewSize: CGSize

    /// URL for the original full-resolution GIF, used when sending.
    public let originalURL: URL

    /// The pixel dimensions of the original rendition.
    public let originalSize: CGSize

    /// Accessibility description for this GIF, if available.
    public let altText: String?

    /// The display name of the user or creator who uploaded this GIF, if available.
    /// Used for content attribution as required by provider terms of service.
    public let username: String?

    /// URL to fire when this GIF is displayed to the user (analytics).
    public let onloadURL: URL?

    /// URL to fire when the user clicks/selects this GIF (analytics).
    public let onclickURL: URL?

    /// URL to fire when this GIF is sent in a message (analytics).
    public let onsentURL: URL?

    public init(
        id: String,
        title: String,
        previewURL: URL,
        previewSize: CGSize,
        originalURL: URL,
        originalSize: CGSize,
        altText: String? = nil,
        username: String? = nil,
        onloadURL: URL? = nil,
        onclickURL: URL? = nil,
        onsentURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.previewSize = previewSize
        self.originalURL = originalURL
        self.originalSize = originalSize
        self.altText = altText
        self.username = username
        self.onloadURL = onloadURL
        self.onclickURL = onclickURL
        self.onsentURL = onsentURL
    }
}
