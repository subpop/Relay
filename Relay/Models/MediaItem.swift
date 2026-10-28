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

import MatrixKit

/// The placeholder caption sent with a gallery that has no text, so
/// clients without gallery support still show something.
enum GallerySummary {
    static func text(for count: Int) -> String {
        "\(count) attachments"
    }
}

/// What a media view needs to render one attachment: a standalone
/// message's media or a single item of a gallery.
struct MediaItem {
    var download: MediaFileHelper.Download?
    var info: MediaInfo?
    /// Caption shown with the attachment, when it has one.
    var caption: String?
    /// Name to show when `download` is unavailable.
    var fallbackName: String

    init(
        download: MediaFileHelper.Download?, info: MediaInfo?,
        caption: String? = nil, fallbackName: String
    ) {
        self.download = download
        self.info = info
        self.caption = caption
        self.fallbackName = fallbackName
    }

    /// The media of a single-attachment message.
    init(message: ObservableTimelineEvent) {
        let info: MediaInfo? =
            switch message.kind {
            case .image(_, _, let info), .video(_, _, let info),
                .audio(_, _, let info), .file(_, _, let info),
                .sticker(_, _, let info):
                info
            default:
                nil
            }
        self.init(
            download: message.mediaDownload, info: info,
            caption: message.caption, fallbackName: message.body)
    }

    /// One item of a gallery message. As with single attachments, the
    /// item body is a caption only when it differs from the filename.
    init(galleryItem item: GalleryItem) {
        let name = item.filename ?? item.body ?? ""
        let caption = item.body.flatMap { $0.isEmpty || $0 == item.filename ? nil : $0 }
        let download = (item.url ?? item.file?.url).map {
            MediaFileHelper.Download(
                mxcURL: $0,
                filename: name,
                mimetype: item.info?.mimeType,
                size: item.info?.size,
                encryptedFile: item.file,
                thumbnailMXCURL: item.info?.thumbnailUrl,
                encryptedThumbnail: item.info?.thumbnailFile)
        }
        self.init(download: download, info: item.info, caption: caption, fallbackName: name)
    }
}
