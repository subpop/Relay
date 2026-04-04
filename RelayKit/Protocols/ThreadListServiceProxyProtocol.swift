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

// ThreadListServiceProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// Provides a paginated list of threads in a room.
///
/// Wraps the SDK's `ThreadListService` for browsing and subscribing
/// to threads within a room.
///
/// ## Topics
///
/// ### Pagination
/// - ``paginateBackwards(numEvents:)``
public protocol ThreadListServiceProxyProtocol: AnyObject, Sendable {
    // Thread list service methods will be populated as the SDK API stabilizes.
    // The ThreadListService is a newer addition to the SDK.
}
