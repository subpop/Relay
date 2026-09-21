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

/// Stores the GIPHY analytics identity.
///
/// - Opt-in (`analytics.giphy.optIn == true`): fetches a `random_id` from
///   `api.giphy.com/v1/randomid` once, stores it as `analytics.giphy.customerID`,
///   and reuses it as `random_id` on all GIPHY requests.
/// - Opt-out (`false`, default): no identifier is stored or sent; analytics
///   pingbacks are not fired at all.
///
/// The store exposes only two members: `currentID` (read) and
/// `bootstrap(apiKey:)` (fetch-once when opted in).
final class GiphyIdentityStore: @unchecked Sendable {
    static let shared = GiphyIdentityStore()

    nonisolated private static let optInKey = "analytics.giphy.optIn"
    nonisolated private static let customerIDKey = "analytics.giphy.customerID"

    /// The current identifier to send as `random_id` to GIPHY.
    ///
    /// - Returns: the persisted `customer_id` when opted in, `nil` otherwise.
    nonisolated var currentID: String? {
        guard UserDefaults.standard.bool(forKey: Self.optInKey) else { return nil }
        return UserDefaults.standard.string(forKey: Self.customerIDKey)
    }

    init() {}

    /// Prepares the identity for this launch.
    ///
    /// Call during app startup and when the user flips the opt-in toggle.
    /// When opted in and no `customerID` is stored, fetches one from the
    /// GIPHY Random ID endpoint and persists it. When opted out, removes any
    /// stored identifier.
    nonisolated func bootstrap(apiKey: String) async {
        if UserDefaults.standard.bool(forKey: Self.optInKey) {
            // Already have a stored ID – nothing to do.
            if UserDefaults.standard.string(forKey: Self.customerIDKey) != nil { return }
            if let fetched = await fetchRandomID(apiKey: apiKey) {
                UserDefaults.standard.set(fetched, forKey: Self.customerIDKey)
            }
            // If fetch fails we leave it nil and will retry on next bootstrap;
            // search/trending will run without `random_id` until then.
        } else {
            // Opted out – remove any stored identifier.
            UserDefaults.standard.removeObject(forKey: Self.customerIDKey)
        }
    }

    // MARK: - Private

    nonisolated private func fetchRandomID(apiKey: String) async -> String? {
        guard !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.giphy.com/v1/randomid")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(GiphyRandomIDResponse.self, from: data)
            return decoded.data.randomID
        } catch {
            return nil
        }
    }
}

// MARK: - Random ID Response

nonisolated private struct GiphyRandomIDResponse: Decodable, Sendable {
    let data: GiphyRandomIDData
}

nonisolated private struct GiphyRandomIDData: Decodable, Sendable {
    let randomID: String
    enum CodingKeys: String, CodingKey {
        case randomID = "random_id"
    }
}
