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

// NotificationClientProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0


/// Fetches notification content for processing push notifications.
///
/// Used in Notification Service Extensions to fetch the full event
/// content for a push notification, enabling rich notification display.
///
/// ## Topics
///
/// ### Fetching Notifications
/// - ``getNotification(roomId:eventId:)``
public protocol NotificationClientProxyProtocol: AnyObject, Sendable {
    /// Fetches the notification status for a specific event.
    ///
    /// - Parameters:
    ///   - roomId: The Matrix room ID.
    ///   - eventId: The event ID.
    /// - Returns: The notification status.
    /// - Throws: If fetching fails.
    func getNotification(roomId: String, eventId: String) async throws -> NotificationStatus
}
