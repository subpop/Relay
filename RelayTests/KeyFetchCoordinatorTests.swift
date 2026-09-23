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
import Testing

@testable import Relay

// MARK: - KeyFetchCoordinatorTests

@MainActor
struct KeyFetchCoordinatorTests {

    @Test func successfulRestoreRecordsCountAndClears() async {
        var reported: [RelayError] = []
        let coordinator = KeyFetchCoordinator(
            restore: { _, progress in
                await progress?(.init(phase: .importing, completed: 2, total: 4))
                return 2
            },
            report: { reported.append($0) })
        coordinator.startBackupRestore(title: "Test", backupKey: Data([1, 2, 3]))
        await waitUntilNotRestoring(coordinator)
        #expect(coordinator.lastRestoredSessionCount == 2)
        #expect(reported.isEmpty)
    }

    @Test func progressSnapshotsUpdateTheEntry() async {
        let gate = AsyncStream<Void>.makeStream()
        var reported: [RelayError] = []
        let coordinator = KeyFetchCoordinator(
            restore: { _, progress in
                await progress?(.init(phase: .fetching))
                await progress?(.init(phase: .importing, completed: 3, total: 4))
                for await _ in gate.stream {
                    break
                }
                return 3
            },
            report: { reported.append($0) })
        coordinator.startBackupRestore(title: "Test", backupKey: Data())
        for _ in 0..<1_000 {
            if coordinator.tasks.first?.completed == 3 {
                break
            }
            await Task.yield()
        }
        let entry = coordinator.tasks.first
        #expect(entry?.total == 4)
        #expect(entry?.fraction == 0.75)
        gate.continuation.yield(())
        await waitUntilNotRestoring(coordinator)
        #expect(coordinator.lastRestoredSessionCount == 3)
        #expect(reported.isEmpty)
    }

    @Test func cancelClearsEntryQuietly() async {
        var reported: [RelayError] = []
        let coordinator = KeyFetchCoordinator(
            restore: { _, progress in
                await progress?(.init(phase: .fetching))
                try await Task.sleep(for: .seconds(30))
                return 0
            },
            report: { reported.append($0) })
        coordinator.startBackupRestore(title: "Test", backupKey: Data())
        for _ in 0..<1_000 {
            if !coordinator.tasks.isEmpty {
                break
            }
            await Task.yield()
        }
        guard let id = coordinator.tasks.first?.id else {
            Issue.record("Expected a running restore entry.")
            return
        }
        coordinator.cancel(id: id)
        await waitUntilNotRestoring(coordinator)
        #expect(coordinator.lastRestoredSessionCount == nil)
        #expect(reported.isEmpty)
    }

    @Test func matrixCancellationClearsEntryQuietly() async {
        var reported: [RelayError] = []
        let coordinator = KeyFetchCoordinator(
            restore: { _, _ in throw MatrixError.cancelled },
            report: { reported.append($0) })
        coordinator.startBackupRestore(title: "Test", backupKey: Data())
        await waitUntilNotRestoring(coordinator)
        #expect(coordinator.lastRestoredSessionCount == nil)
        #expect(reported.isEmpty)
    }

    @Test func failureIsReported() async {
        struct Boom: Error {}
        var reported: [RelayError] = []
        let coordinator = KeyFetchCoordinator(
            restore: { _, _ in throw Boom() },
            report: { reported.append($0) })
        coordinator.startBackupRestore(title: "Test", backupKey: Data())
        await waitUntilNotRestoring(coordinator)
        #expect(reported.count == 1)
        guard case .keyBackupRestoreFailed = reported.first else {
            Issue.record("Expected keyBackupRestoreFailed, got \(String(describing: reported.first)).")
            return
        }
    }

    private func waitUntilNotRestoring(_ coordinator: KeyFetchCoordinator) async {
        for _ in 0..<10_000 {
            if !coordinator.isRestoring {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the restore to finish.")
    }
}
