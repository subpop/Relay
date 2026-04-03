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

// ClientBuilderProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A builder for constructing a ``ClientProxy`` with the desired configuration.
///
/// Wraps the Matrix SDK `ClientBuilder` with a Swift-friendly fluent API.
/// Call configuration methods to set up the store path, homeserver, proxy,
/// and encryption settings, then call ``build()`` to create the client.
///
/// ```swift
/// let client = try await ClientBuilderProxy()
///     .homeserverUrl("https://matrix.org")
///     .sessionPaths(dataPath: dataDir, cachePath: cacheDir)
///     .build()
/// ```
///
/// ## Topics
///
/// ### Configuration
/// - ``homeserverUrl(_:)``
/// - ``serverName(_:)``
/// - ``serverNameOrHomeserverUrl(_:)``
/// - ``sessionPaths(dataPath:cachePath:)``
/// - ``username(_:)``
///
/// ### Building
/// - ``build()``
public final class ClientBuilderProxy: @unchecked Sendable {
    private var builder: ClientBuilder

    /// Creates a new client builder.
    public init() {
        self.builder = ClientBuilder()
    }

    /// Sets the homeserver URL.
    ///
    /// - Parameter url: The homeserver URL string.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func homeserverUrl(_ url: String) -> ClientBuilderProxy {
        builder = builder.homeserverUrl(url: url)
        return self
    }

    /// Sets the server name for well-known lookup.
    ///
    /// - Parameter serverName: The server name (e.g. `matrix.org`).
    /// - Returns: This builder for chaining.
    @discardableResult
    public func serverName(_ serverName: String) -> ClientBuilderProxy {
        builder = builder.serverName(serverName: serverName)
        return self
    }

    /// Sets either a server name or homeserver URL.
    ///
    /// - Parameter serverNameOrUrl: The server name or URL.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func serverNameOrHomeserverUrl(_ serverNameOrUrl: String) -> ClientBuilderProxy {
        builder = builder.serverNameOrHomeserverUrl(serverNameOrUrl: serverNameOrUrl)
        return self
    }

    /// Sets the session store paths.
    ///
    /// - Parameters:
    ///   - dataPath: The path for persistent data.
    ///   - cachePath: The path for cache data.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func sessionPaths(dataPath: String, cachePath: String) -> ClientBuilderProxy {
        builder = builder.sessionPaths(dataPath: dataPath, cachePath: cachePath)
        return self
    }

    /// Sets the username for the session.
    ///
    /// - Parameter username: The Matrix username.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func username(_ username: String) -> ClientBuilderProxy {
        builder = builder.username(username: username)
        return self
    }

    /// Sets the user agent string.
    ///
    /// - Parameter userAgent: The user agent string.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func userAgent(_ userAgent: String) -> ClientBuilderProxy {
        builder = builder.userAgent(userAgent: userAgent)
        return self
    }

    /// Sets an HTTP proxy URL.
    ///
    /// - Parameter url: The proxy URL.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func proxy(_ url: String) -> ClientBuilderProxy {
        builder = builder.proxy(url: url)
        return self
    }

    /// Uses an in-memory store instead of SQLite.
    ///
    /// - Returns: This builder for chaining.
    @discardableResult
    public func inMemoryStore() -> ClientBuilderProxy {
        builder = builder.inMemoryStore()
        return self
    }

    /// Disables SSL certificate verification.
    ///
    /// - Warning: Only use this for development/testing.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func disableSslVerification() -> ClientBuilderProxy {
        builder = builder.disableSslVerification()
        return self
    }

    /// Enables automatic cross-signing setup.
    ///
    /// - Parameter enabled: Whether to auto-enable cross-signing.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func autoEnableCrossSigning(_ enabled: Bool) -> ClientBuilderProxy {
        builder = builder.autoEnableCrossSigning(autoEnableCrossSigning: enabled)
        return self
    }

    /// Enables automatic backup setup.
    ///
    /// - Parameter enabled: Whether to auto-enable backups.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func autoEnableBackups(_ enabled: Bool) -> ClientBuilderProxy {
        builder = builder.autoEnableBackups(autoEnableBackups: enabled)
        return self
    }

    /// Sets the sliding sync version builder.
    ///
    /// - Parameter versionBuilder: The sliding sync version configuration.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func slidingSyncVersionBuilder(_ versionBuilder: SlidingSyncVersionBuilder) -> ClientBuilderProxy {
        builder = builder.slidingSyncVersionBuilder(versionBuilder: versionBuilder)
        return self
    }

    /// Sets the request configuration.
    ///
    /// - Parameter config: The request configuration.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func requestConfig(_ config: RequestConfig) -> ClientBuilderProxy {
        builder = builder.requestConfig(config: config)
        return self
    }

    /// Sets the session delegate for keychain operations.
    ///
    /// - Parameter delegate: The session delegate.
    /// - Returns: This builder for chaining.
    @discardableResult
    public func setSessionDelegate(_ delegate: ClientSessionDelegate) -> ClientBuilderProxy {
        builder = builder.setSessionDelegate(sessionDelegate: delegate)
        return self
    }

    /// Builds the client with the configured options.
    ///
    /// - Returns: A configured ``ClientProxy``.
    /// - Throws: `ClientBuildError` if the build fails.
    public func build() async throws -> ClientProxy {
        let client = try await builder.build()
        return try ClientProxy(client: client)
    }
}
