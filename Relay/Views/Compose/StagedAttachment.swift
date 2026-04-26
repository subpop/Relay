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

import AppKit
import Foundation

/// A file staged for sending, shown as a capsule in the compose bar.
///
/// Each ``StagedAttachment`` holds the local file URL (already copied to a temp directory),
/// a display-friendly filename, an optional thumbnail for images/videos, and an optional
/// user-provided caption (alt-text).
struct StagedAttachment: Identifiable {
    let id = UUID()

    /// Local file URL (temp-directory copy, security-scoped access already resolved).
    let url: URL

    /// The original filename for display.
    let filename: String

    /// A small thumbnail image for image/video attachments, or `nil` for other file types.
    let thumbnail: NSImage?

    /// User-provided alt-text / caption. Empty string means no caption.
    var caption: String = ""
}
