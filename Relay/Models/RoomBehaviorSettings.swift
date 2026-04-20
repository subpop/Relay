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

import Foundation
import Observation
import SwiftUI

/// Per-room behavior overrides stored locally in UserDefaults.
///
/// Each field is optional. When `nil`, the corresponding global setting from
/// `@AppStorage` is used. When set, the per-room value takes precedence.
struct RoomBehaviorOverrides: Codable, Equatable {
    /// Override for GIF animation behavior. `nil` uses the global default.
    var animateGIFs: String?

    /// Override for showing media previews. `nil` uses the global default.
    var showMediaPreviews: Bool?

    /// Override for showing URL link previews. `nil` uses the global default.
    var showURLPreviews: Bool?

    /// Override for showing join/part membership events. `nil` uses the global default.
    var showMembershipEvents: Bool?

    /// Override for showing room state change events. `nil` uses the global default.
    var showStateEvents: Bool?

    /// Whether all overrides are nil (i.e. the room uses all global defaults).
    var isEmpty: Bool {
        animateGIFs == nil
            && showMediaPreviews == nil
            && showURLPreviews == nil
            && showMembershipEvents == nil
            && showStateEvents == nil
    }
}

/// Manages per-room behavior overrides, persisted as JSON in UserDefaults.
///
/// Use the shared ``RoomBehaviorStore/shared`` instance. Access per-room
/// overrides via ``overrides(for:)`` and persist changes via ``setOverrides(_:for:)``.
@Observable
final class RoomBehaviorStore {
    static let shared = RoomBehaviorStore()

    private static let storageKey = "roomBehaviorOverrides"
    private var cache: [String: RoomBehaviorOverrides] = [:]

    private init() {
        load()
    }

    /// Returns the behavior overrides for a room, or an empty set if none exist.
    func overrides(for roomId: String) -> RoomBehaviorOverrides {
        cache[roomId] ?? RoomBehaviorOverrides()
    }

    /// Saves behavior overrides for a room. Removes the entry if all values are nil.
    func setOverrides(_ overrides: RoomBehaviorOverrides, for roomId: String) {
        if overrides.isEmpty {
            cache.removeValue(forKey: roomId)
        } else {
            cache[roomId] = overrides
        }
        save()
    }

    /// Clears all overrides for a room, restoring global defaults.
    func clearOverrides(for roomId: String) {
        cache.removeValue(forKey: roomId)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: RoomBehaviorOverrides].self, from: data)
        else { return }
        cache = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - Environment Key

/// An environment key that passes a per-room GIF animation override to child views.
/// When `nil`, the child view uses its own `@AppStorage` global default.
private struct GIFAnimationOverrideKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// A per-room override for GIF animation mode.
    /// When set, ``ImageMessageView`` uses this value instead of the global `@AppStorage` default.
    var gifAnimationOverride: String? {
        get { self[GIFAnimationOverrideKey.self] }
        set { self[GIFAnimationOverrideKey.self] = newValue }
    }
}
