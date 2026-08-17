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
import RelayInterface

/// Observes typing notifications for a room and resolves user display names
/// and avatar URLs.
///
/// ``TypingNotificationObserver`` subscribes to the SDK's typing notification
/// stream, filters out the current user, resolves display names and avatars
/// asynchronously, and publishes the result via a callback. Removal is
/// debounced by 1 second to prevent indicator jumpiness.
final class TypingNotificationObserver {

    private var typingTask: Task<Void, Never>?
    @ObservationIgnored private var typingHandle: TaskHandle?

    private let currentUserId: String?

    /// Called when the resolved typing users list changes.
    var onTypingUsersChanged: (([TypingUser]) -> Void)?

    init(currentUserId: String?) {
        self.currentUserId = currentUserId
    }

    /// Subscribes to typing notifications on the given room and begins
    /// resolving display names and avatars.
    func observe(room: Room) {
        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        let listener = SDKListener<[String]> { userIds in
            continuation.yield(userIds)
        }
        typingHandle = room.subscribeToTypingNotifications(listener: listener)

        typingTask = Task { [weak self] in
            // A child task that resolves display names and avatar URLs.
            // Cancelled and replaced each time a new typing notification
            // arrives, so stale resolutions never block clearing the
            // indicator when the SDK sends an empty user list.
            var resolveTask: Task<Void, Never>?

            for await userIds in stream {
                guard let self else { break }
                resolveTask?.cancel()

                let filtered = userIds.filter { $0 != self.currentUserId }

                // Debounce removal: keep the indicator visible briefly
                // so rapid start/stop cycles don't cause timeline
                // jumpiness. If a new typing notification arrives before
                // the delay expires, `resolveTask?.cancel()` above will
                // prevent the stale clear.
                if filtered.isEmpty {
                    resolveTask = Task {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled {
                            self.onTypingUsersChanged?([])
                        }
                    }
                    continue
                }

                resolveTask = Task {
                    var users: [TypingUser] = []
                    for userId in filtered {
                        if Task.isCancelled { return }
                        let name: String
                        if let displayName = try? await room.memberDisplayName(userId: userId), !displayName.isEmpty {
                            name = displayName
                        } else {
                            name = userId
                        }
                        let avatarURL = try? await room.memberAvatarUrl(userId: userId)
                        if Task.isCancelled { return }
                        users.append(TypingUser(id: userId, displayName: name, avatarURL: avatarURL))
                    }
                    self.onTypingUsersChanged?(users)
                }
            }

            resolveTask?.cancel()
        }
    }

    /// Cancels the observation task and releases SDK handles.
    func teardown() {
        typingTask?.cancel()
        typingTask = nil
        typingHandle = nil
    }
}
