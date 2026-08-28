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

private final class BundleAnchor {}

public enum AppGroup: Sendable {
    nonisolated public static let identifier: String = {
        guard let identifier = Bundle(for: BundleAnchor.self).object(forInfoDictionaryKey: "RelayAppGroupIdentifier") as? String else {
            fatalError("RelayAppGroupIdentifier missing from RelayKit's Info.plist")
        }
        return identifier
    }()

    nonisolated public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
