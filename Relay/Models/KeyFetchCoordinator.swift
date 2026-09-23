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
import MatrixKit

/// A background key-backup restore tracked by ``KeyFetchCoordinator``.
///
/// `task` is nil when the work is not user-cancellable; `fraction` is
/// nil while the total is unknown (indeterminate progress).
struct KeyFetchTask: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var completed: Int?
    var total: Int?
    var fraction: Double?
    var task: Task<Void, Never>?
}

/// Runs megolm key-backup restores off the verification sheet and
/// publishes their progress for the sidebar banner.
///
/// Success and user cancellation clear the entry silently; any other
/// failure is surfaced through the report handler (the app's
/// `ErrorReporter`), so callers stay thin.
@Observable
@MainActor
final class KeyFetchCoordinator {
    /// Currently running restores, in start order.
    var tasks: [KeyFetchTask] = []

    /// Sessions imported by the most recent successful restore.
    var lastRestoredSessionCount: Int?

    /// Performs the restore. Injected so tests can drive the
    /// coordinator without a live Matrix session.
    private let restore: (
        Data,
        (@Sendable (KeyFetchProgress) async -> Void)?
    ) async throws -> Int

    /// Surfaces non-cancellation failures to the user.
    private let report: (RelayError) -> Void

    init(
        restore: @escaping (
            Data,
            (@Sendable (KeyFetchProgress) async -> Void)?
        ) async throws -> Int,
        report: @escaping (RelayError) -> Void
    ) {
        self.restore = restore
        self.report = report
    }

    /// Whether a restore is currently running.
    var isRestoring: Bool { !tasks.isEmpty }

    /// Start restoring backed-up sessions in the background. The entry
    /// is always cancellable: cancelling keeps already-imported
    /// sessions and clears the entry quietly.
    ///
    /// Progress crosses into the coordinator through an `AsyncStream`:
    /// the `@Sendable` progress closure only captures the stream's
    /// `Sendable` continuation, while a MainActor-bound forwarder
    /// applies snapshots to the entry.
    func startBackupRestore(title: String, backupKey: Data) {
        var entry = KeyFetchTask(title: title, task: nil)
        let id = entry.id
        entry.task = Task { [weak self] in
            guard let self else { return }
            let (progresses, continuation) = AsyncStream<KeyFetchProgress>.makeStream()
            let forwarder = Task {
                for await progress in progresses {
                    self.update(
                        id: id, completed: progress.completed,
                        total: progress.total, fraction: progress.fraction)
                }
            }
            do {
                let count = try await self.restore(backupKey) { progress in
                    continuation.yield(progress)
                }
                continuation.finish()
                await forwarder.value
                self.finish(id: id, restoredCount: count)
            } catch {
                continuation.finish()
                await forwarder.value
                self.finish(id: id, error: error)
            }
        }
        tasks.append(entry)
    }

    /// Cancel a running restore. Already-imported sessions are kept.
    func cancel(id: UUID) {
        tasks.first(where: { $0.id == id })?.task?.cancel()
    }

    /// Cancel every running restore (logout path).
    func stopAll() {
        for entry in tasks {
            entry.task?.cancel()
        }
    }

    private func update(id: UUID, completed: Int?, total: Int?, fraction: Double?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].completed = completed
        tasks[index].total = total
        tasks[index].fraction = fraction
    }

    private func finish(id: UUID, restoredCount: Int) {
        tasks.removeAll(where: { $0.id == id })
        lastRestoredSessionCount = restoredCount
    }

    private func finish(id: UUID, error: any Error) {
        tasks.removeAll(where: { $0.id == id })
        if let matrixError = error as? MatrixError, matrixError.isCancellation {
            return
        }
        if error is CancellationError {
            return
        }
        report(.keyBackupRestoreFailed(error.localizedDescription))
    }
}
