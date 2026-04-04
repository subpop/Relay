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

// SyncServiceBuilderProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// A builder for constructing a ``SyncServiceProxy`` with configuration options.
///
/// Wraps the SDK's `SyncServiceBuilder` with a Swift-friendly fluent API.
///
/// ```swift
/// let syncService = try await SyncServiceBuilderProxy(builder: client.syncService())
///     .withOfflineMode()
///     .build()
/// ```
///
/// ## Topics
///
/// ### Configuration
/// - ``withOfflineMode()``
/// - ``withSharePos(enable:)``
///
/// ### Building
/// - ``build()``
public final class SyncServiceBuilderProxy: @unchecked Sendable {
    private var builder: SyncServiceBuilder

    /// Creates a sync service builder proxy.
    ///
    /// - Parameter builder: The SDK sync service builder.
    public init(builder: SyncServiceBuilder) {
        self.builder = builder
    }

    /// Enables offline mode for the sync service.
    ///
    /// - Returns: This builder for chaining.
    @discardableResult
    public func withOfflineMode() -> SyncServiceBuilderProxy {
        builder = builder.withOfflineMode()
        return self
    }

    /// Enables or disables sharing the sync position.
    ///
    /// - Parameter enable: Whether to share the sync position.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func withSharePos(enable: Bool) -> SyncServiceBuilderProxy {
        builder = builder.withSharePos(enable: enable)
        return self
    }

    /// Builds the sync service proxy.
    ///
    /// - Returns: A configured ``SyncServiceProxy``.
    /// - Throws: `ClientError` if building fails.
    public func build() async throws -> SyncServiceProxy {
        let syncService = try await builder.finish()
        return SyncServiceProxy(syncService: syncService)
    }
}
