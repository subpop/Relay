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

/// A curated Matrix homeserver shown in the server picker.
struct HomeServer: Identifiable {
    /// The homeserver domain (e.g. `"matrix.org"`).
    let id: String
    /// The display name (e.g. `"Matrix.org"`).
    let name: String
    /// A short description for display in the picker.
    let description: String
    /// An SF Symbol name for the server's row icon.
    let icon: String
    /// A URL where users can learn more about this server.
    let learnMoreURL: URL
    /// A web registration URL for servers that don't support OAuth.
    ///
    /// When set, the server row shows a "Sign Up" button that opens this URL
    /// in the browser instead of the OAuth "Sign in with Browser" button.
    let signUpURL: URL?

    /// Whether this server supports OAuth/OIDC login via the browser flow.
    var supportsOAuth: Bool { signUpURL == nil }

    /// The primary servers shown directly in the picker.
    static let primary: [HomeServer] = [
        HomeServer(
            id: "mozilla.org",
            name: "Mozilla",
            description: "Run by Mozilla, the makers of Firefox.",
            icon: "flame.fill",
            learnMoreURL: URL(string: "https://mozilla.org")!,
            signUpURL: nil
        ),
        HomeServer(
            id: "gitter.im",
            name: "Gitter",
            description: "Popular with open source and developer communities.",
            icon: "chevron.left.forwardslash.chevron.right",
            learnMoreURL: URL(string: "https://gitter.im")!,
            signUpURL: nil
        ),
    ]

    /// Additional servers shown behind a disclosure group.
    static let more: [HomeServer] = [
        HomeServer(
            id: "matrix.org",
            name: "Matrix.org",
            description: "Run by the Matrix Foundation.",
            icon: "globe",
            learnMoreURL: URL(string: "https://matrix.org")!,
            signUpURL: nil
        ),
        HomeServer(
            id: "unredacted.org",
            name: "Unredacted",
            description: "Privacy-focused server run by Unredacted, based in the US.",
            icon: "lock.shield",
            learnMoreURL: URL(string: "https://unredacted.org")!,
            signUpURL: URL(string: "https://element.unredacted.org/#/register")!
        ),
        HomeServer(
            id: "tchncs.de",
            name: "tchncs.de",
            description: "One of the largest community servers, based in Germany.",
            icon: "server.rack",
            learnMoreURL: URL(string: "https://tchncs.de")!,
            signUpURL: URL(string: "https://chat.tchncs.de/#/register")!
        ),
    ]

    /// URL to browse the full public homeserver directory.
    static let directoryURL = URL(string: "https://servers.joinmatrix.org/")!
}
