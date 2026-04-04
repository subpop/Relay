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

// SpaceServiceProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// A proxy that wraps the Matrix SDK `SpaceService`.
///
/// Provides access to Matrix space hierarchies and space membership.
/// The SpaceService API is evolving; this proxy will be expanded
/// as the SDK stabilizes.
public final class SpaceServiceProxy: SpaceServiceProxyProtocol, @unchecked Sendable {
    private let service: SpaceService

    /// Creates a space service proxy.
    ///
    /// - Parameter service: The SDK space service instance.
    public init(service: SpaceService) {
        self.service = service
    }
}
