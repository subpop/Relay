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

// UserIdentityProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// A user's end-to-end encryption identity.
///
/// Provides methods to pin, verify, or inspect a user's cross-signing keys.
/// Pinning trusts the user's current keys without full verification.
/// Verification marks the identity as cryptographically verified.
///
/// ## Topics
///
/// ### State
/// - ``isVerified()``
/// - ``hasVerificationViolation()``
/// - ``wasPreviouslyVerified()``
///
/// ### Actions
/// - ``pin()``
/// - ``withdrawVerification()``
///
/// ### Keys
/// - ``masterKey()``
public protocol UserIdentityProxyProtocol: AnyObject, Sendable {
    /// Whether the user's identity is verified.
    ///
    /// - Returns: `true` if verified.
    func isVerified() -> Bool

    /// Whether there is a verification violation for this identity.
    ///
    /// - Returns: `true` if a violation exists.
    func hasVerificationViolation() -> Bool

    /// Whether the user was previously verified but is no longer.
    ///
    /// - Returns: `true` if previously verified.
    func wasPreviouslyVerified() -> Bool

    /// Pins the user's identity, trusting their current keys.
    ///
    /// - Throws: If pinning fails.
    func pin() async throws

    /// Withdraws verification from the user's identity.
    ///
    /// - Throws: If withdrawing fails.
    func withdrawVerification() async throws

    /// Returns the user's master cross-signing key.
    ///
    /// - Returns: The master key string, or `nil`.
    func masterKey() -> String? // swiftlint:disable:this inclusive_language
}
