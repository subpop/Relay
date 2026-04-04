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

// SpaceServiceProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// Provides access to Matrix space hierarchies.
///
/// Wraps the SDK's `SpaceService` for browsing the tree of rooms
/// within a space and managing space membership.
///
/// ## Topics
///
/// ### Hierarchy
/// - ``getRoomHierarchy(roomId:limit:maxDepth:pageToken:via:)``
public protocol SpaceServiceProxyProtocol: AnyObject, Sendable {
    // Space service methods will be added as the SDK API stabilizes.
    // The SpaceService FFI type is relatively new and minimal.
}
