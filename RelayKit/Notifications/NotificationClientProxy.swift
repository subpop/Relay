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

// NotificationClientProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// A proxy that wraps the Matrix SDK `NotificationClient`.
///
/// Used in Notification Service Extensions to fetch event content
/// for push notification display.
public final class NotificationClientProxy: NotificationClientProxyProtocol, @unchecked Sendable {
    private let client: NotificationClient

    /// Creates a notification client proxy.
    ///
    /// - Parameter client: The SDK notification client instance.
    public init(client: NotificationClient) {
        self.client = client
    }

    /// Fetches the notification status for a specific event.
    public func getNotification(roomId: String, eventId: String) async throws -> NotificationStatus {
        try await client.getNotification(roomId: roomId, eventId: eventId)
    }
}
