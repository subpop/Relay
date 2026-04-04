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

// UserIdentityProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// A proxy that wraps a Matrix SDK `UserIdentity`.
///
/// Provides methods to inspect and manage a user's cross-signing
/// identity state.
public final class UserIdentityProxy: UserIdentityProxyProtocol, @unchecked Sendable {
    private let identity: UserIdentity

    /// Creates a user identity proxy.
    ///
    /// - Parameter identity: The SDK user identity instance.
    public init(identity: UserIdentity) {
        self.identity = identity
    }

    public func isVerified() -> Bool {
        identity.isVerified()
    }

    public func hasVerificationViolation() -> Bool {
        identity.hasVerificationViolation()
    }

    public func wasPreviouslyVerified() -> Bool {
        identity.wasPreviouslyVerified()
    }

    public func pin() async throws {
        try await identity.pin()
    }

    public func withdrawVerification() async throws {
        try await identity.withdrawVerification()
    }

    // swiftlint:disable:next inclusive_language
    public func masterKey() -> String? {
        identity.masterKey()
    }
}
