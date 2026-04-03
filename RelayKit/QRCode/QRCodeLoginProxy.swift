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

// QRCodeLoginProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0


/// Handles QR code-based login for signing in on a new device.
///
/// Wraps the SDK's QR code login handlers for both granting and
/// receiving login via QR code scanning.
///
/// ## Topics
///
/// ### Login Flows
/// - ``createGrantHandler(client:)``
/// - ``createLoginHandler(client:oidcConfiguration:)``
public final class QRCodeLoginProxy: @unchecked Sendable {
    /// Creates a QR code login proxy.
    public init() {}

    /// Creates a handler for granting login to another device via QR code.
    ///
    /// - Parameter client: The authenticated client proxy.
    /// - Returns: The grant login handler.
    public func createGrantHandler(client: any ClientProxyProtocol) -> GrantLoginWithQrCodeHandler {
        client.newGrantLoginWithQrCodeHandler()
    }

    /// Creates a handler for logging in by scanning a QR code.
    ///
    /// - Parameters:
    ///   - client: The client proxy (may not be authenticated).
    ///   - oidcConfiguration: The OIDC configuration.
    /// - Returns: The login handler.
    public func createLoginHandler(client: any ClientProxyProtocol, oidcConfiguration: OidcConfiguration) -> LoginWithQrCodeHandler {
        client.newLoginWithQrCodeHandler(oidcConfiguration: oidcConfiguration)
    }
}
