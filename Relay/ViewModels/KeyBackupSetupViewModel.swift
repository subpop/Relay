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

// MARK: - KeyBackupSetupViewModel

/// Drives the sheet that creates the account's first key backup and shows
/// the user the recovery key to keep.
@Observable
@MainActor
final class KeyBackupSetupViewModel: Identifiable {

    enum State: Equatable {
        case intro
        case creating
        /// The backup exists; this is the only time its recovery key is shown.
        case created(recoveryKey: String)
        case failed(String)
    }

    private(set) var state: State = .intro

    /// The user confirmed they have kept the recovery key. Leaving the
    /// created state is gated on it, since the key cannot be shown again.
    var hasSavedRecoveryKey = false

    private(set) var didCopyRecoveryKey = false

    private let create: () async throws -> String
    private let copy: @MainActor (String) -> Void

    /// - Parameters:
    ///   - create: Creates the backup and returns its recovery key.
    ///   - copy: Puts the recovery key on the pasteboard. The default
    ///     marks it concealed so clipboard managers skip it.
    init(
        create: @escaping () async throws -> String,
        copy: @escaping @MainActor (String) -> Void = KeyBackupSetupViewModel.copyConcealed
    ) {
        self.create = create
        self.copy = copy
    }

    /// The recovery key, once created.
    var recoveryKey: String? {
        if case .created(let key) = state { return key }
        return nil
    }

    /// The sheet may close without losing a key the user still needs.
    var canFinish: Bool {
        switch state {
        case .created: hasSavedRecoveryKey
        case .creating: false
        case .intro, .failed: true
        }
    }

    func createBackup() async {
        switch state {
        case .intro, .failed: break
        case .creating, .created: return
        }
        state = .creating
        do {
            state = .created(recoveryKey: try await create())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func copyRecoveryKey() {
        guard let recoveryKey else { return }
        copy(recoveryKey)
        didCopyRecoveryKey = true
    }

    static func copyConcealed(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}
