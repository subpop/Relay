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
import LiveKit
import os

/// A LiveKit `Logger` implementation that forwards all LiveKit SDK log output
/// through `os.Logger` with a `[RTC]` prefix on every message so calling-related
/// logs can be filtered out of the Console with a single token.
///
/// Install once, as early as possible (before any `LiveKit.Room` is created).
struct LiveKitLogBridge: LiveKit.Logger {
    private static let osLogger = os.Logger(subsystem: "RelayKit", category: "LiveKitSDK")

    // swiftlint:disable:next function_parameter_count
    func log(
        _ message: @autoclosure () -> CustomStringConvertible,
        _ level: LiveKit.LogLevel,
        source: @autoclosure () -> String?,
        file _: StaticString,
        type: Any.Type,
        function: StaticString,
        line _: UInt,
        metaData: ScopedMetadataContainer
    ) {
        let rendered: String = {
            let typeName = String(describing: type)
            let meta: String
            if metaData.isEmpty {
                meta = ""
            } else {
                meta = " [" + metaData.map { "\($0): \($1)" }.joined(separator: ", ") + "]"
            }
            return "[RTC] \(typeName).\(function) \(message().description)\(meta)"
        }()

        // SECURITY: LiveKit SDK log content is at the SDK's discretion and
        // can include connection JWTs, signaling URLs, peer identities, etc.
        // Mark as .private so the Console redacts it on release; developers
        // can still see the messages by enabling unredacted logging in Xcode.
        switch level {
        case .debug:
            Self.osLogger.debug("\(rendered, privacy: .private)")
        case .info:
            Self.osLogger.info("\(rendered, privacy: .private)")
        case .warning:
            Self.osLogger.warning("\(rendered, privacy: .private)")
        case .error:
            Self.osLogger.error("\(rendered, privacy: .private)")
        }
    }
}

/// Installs ``LiveKitLogBridge`` exactly once, regardless of how many times
/// ``install()`` is called. Safe to invoke from any thread; the actual swap
/// runs on first access of the static initializer.
enum LiveKitLogBridgeInstaller {
    private static let installed: Void = {
        LiveKitSDK.setLogger(LiveKitLogBridge())
    }()

    static func install() {
        _ = installed
    }
}
