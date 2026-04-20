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

/// A parsed Matrix user identifier with separate username and homeserver components.
struct MatrixID: Equatable {
    var username = ""
    var homeserver = ""

    var isValid: Bool {
        !username.isEmpty && !homeserver.isEmpty && homeserver.contains(".")
    }
}

/// A `ParseableFormatStyle` that converts between ``MatrixID`` and the `@user:homeserver` string format.
struct MatrixIDFormat: ParseableFormatStyle {
    var parseStrategy: MatrixIDParseStrategy { MatrixIDParseStrategy() }

    func format(_ value: MatrixID) -> String {
        guard !value.username.isEmpty || !value.homeserver.isEmpty else { return "" }
        return "@\(value.username):\(value.homeserver)"
    }
}

/// Parses `@user:homeserver` strings into ``MatrixID`` values.
struct MatrixIDParseStrategy: ParseStrategy {
    func parse(_ value: String) throws -> MatrixID {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return MatrixID() }

        guard trimmed.hasPrefix("@") else {
            throw FormatError.missingPrefix
        }
        let body = trimmed.dropFirst()
        guard let colon = body.firstIndex(of: ":") else {
            throw FormatError.missingColon
        }
        let username = String(body[body.startIndex..<colon])
        let homeserver = String(body[body.index(after: colon)...])
        guard !username.isEmpty else {
            throw FormatError.emptyUsername
        }
        guard !homeserver.isEmpty, homeserver.contains(".") else {
            throw FormatError.invalidHomeserver
        }
        return MatrixID(username: username, homeserver: homeserver)
    }

    enum FormatError: LocalizedError {
        case missingPrefix, missingColon, emptyUsername, invalidHomeserver

        var errorDescription: String? {
            switch self {
            case .missingPrefix: "Matrix ID must start with @"
            case .missingColon: "Use the format @user:homeserver"
            case .emptyUsername: "Username cannot be empty"
            case .invalidHomeserver: "Invalid homeserver address"
            }
        }
    }
}
