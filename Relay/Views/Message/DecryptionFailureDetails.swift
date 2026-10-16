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
import MatrixKit
import SwiftUI

/// Shows why an encrypted event could not be decrypted and allows copying its
/// Megolm session ID without displaying the full identifier in the bubble.
struct DecryptionFailureDetails: View {
    let failure: RoomCrypto.DecryptionFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch failure.reason {
                case .unknownSession:
                    Text("Missing room key")
                case .sessionTooOld:
                    Text("Key does not cover this message")
                case .replay:
                    Text("Duplicate encrypted message")
                case .cryptoFailure:
                    Text("Megolm decryption failed")
                case .malformedEnvelope:
                    Text("Malformed encrypted message")
                case .nonJSONPlaintext:
                    Text("Invalid decrypted content")
                }
            }
            .font(.caption2)

            if let sessionId = failure.sessionId {
                HStack(spacing: 6) {
                    Text("Session ID")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(String(sessionId.prefix(12)) + "…")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Button("Copy Session ID", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sessionId, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.secondary)
    }
}
