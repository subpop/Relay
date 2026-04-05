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
import os

private let logger = Logger(subsystem: "RelayKit", category: "LiveKitCredentialService")

/// Fetches LiveKit credentials (WebSocket URL + JWT) for a Matrix room by
/// implementing the MatrixRTC credential exchange flow (MSC4143).
///
/// **Step 1 – Discover the SFU URL**
/// Tries `GET /_matrix/client/unstable/org.matrix.msc4143/rtc/transports`.
/// If that returns 404, falls back to reading `org.matrix.msc4143.rtc_foci`
/// from `GET {server}/.well-known/matrix/client`.
///
/// **Step 2 – Request an OpenID token**
/// `POST /_matrix/client/v3/user/{userId}/openid/request_token` using the
/// session's Matrix access token as Bearer auth.
///
/// **Step 3 – Exchange for a LiveKit JWT**
/// `POST {sfuURL}/get_token` (MSC4143 v2). Falls back to the legacy
/// `POST {sfuURL}/sfu/get` endpoint if the server returns 404.
///
/// Both exchange endpoints return `{ url, jwt }` where `url` is the LiveKit
/// WebSocket address and `jwt` is the LiveKit room access token.
struct LiveKitCredentialService {

    let homeserver: String
    let accessToken: String
    let userID: String
    let deviceID: String

    // MARK: - Public Entry Point

    /// Returns `(livekitWebSocketURL, livekitJWT)` for the given Matrix room.
    func credentials(for roomID: String) async throws -> (url: String, token: String) {
        logger.info("Fetching LiveKit credentials for room \(roomID, privacy: .private)")
        let sfuURL = try await discoverSFUURL()
        logger.info("SFU URL discovered: \(sfuURL)")
        let openIDToken = try await requestOpenIDToken()
        logger.debug("OpenID token obtained")
        return try await fetchLiveKitToken(sfuURL: sfuURL, roomID: roomID, openIDToken: openIDToken)
    }

    // MARK: - Step 1: Discover SFU URL

    private func discoverSFUURL() async throws -> String {
        // Prefer the MSC4143 transports endpoint
        if let url = try? await fetchRTCTransportsURL() {
            return url
        }
        // Fall back to .well-known
        if let url = try? await fetchWellKnownSFUURL() {
            return url
        }
        throw LiveKitCredentialError.sfuURLNotFound
    }

    private func fetchRTCTransportsURL() async throws -> String {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(base)/_matrix/client/unstable/org.matrix.msc4143/rtc/transports") else {
            throw LiveKitCredentialError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LiveKitCredentialError.serverError
        }

        let decoded = try JSONDecoder().decode(RTCTransportsResponse.self, from: data)
        guard let livekit = decoded.transports.first(where: { $0.type == "livekit" }) else {
            throw LiveKitCredentialError.sfuURLNotFound
        }
        return livekit.livekitServiceUrl
    }

    private func fetchWellKnownSFUURL() async throws -> String {
        guard let serverURL = URL(string: homeserver), let host = serverURL.host else {
            throw LiveKitCredentialError.invalidURL
        }
        let scheme = serverURL.scheme ?? "https"
        guard let url = URL(string: "\(scheme)://\(host)/.well-known/matrix/client") else {
            throw LiveKitCredentialError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LiveKitCredentialError.serverError
        }

        let decoded = try JSONDecoder().decode(WellKnownResponse.self, from: data)
        guard let foci = decoded.rtcFoci,
              let first = foci.first(where: { $0.type == "livekit" }) else {
            throw LiveKitCredentialError.sfuURLNotFound
        }
        return first.livekitServiceUrl
    }

    // MARK: - Step 2: Request OpenID Token

    private func requestOpenIDToken() async throws -> OpenIDTokenPayload {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encoded = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        guard let url = URL(string: "\(base)/_matrix/client/v3/user/\(encoded)/openid/request_token") else {
            throw LiveKitCredentialError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LiveKitCredentialError.openIDTokenFailed
        }
        return try JSONDecoder().decode(OpenIDTokenPayload.self, from: data)
    }

    // MARK: - Step 3: Exchange for LiveKit JWT

    private func fetchLiveKitToken(
        sfuURL: String,
        roomID: String,
        openIDToken: OpenIDTokenPayload
    ) async throws -> (url: String, token: String) {
        // Try the v2 endpoint first, fall back to legacy
        if let result = try? await fetchLiveKitTokenV2(sfuURL: sfuURL, roomID: roomID, openIDToken: openIDToken) {
            return result
        }
        return try await fetchLiveKitTokenLegacy(sfuURL: sfuURL, roomID: roomID, openIDToken: openIDToken)
    }

    private func fetchLiveKitTokenV2(
        sfuURL: String,
        roomID: String,
        openIDToken: OpenIDTokenPayload
    ) async throws -> (url: String, token: String) {
        let base = sfuURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(base)/get_token") else {
            throw LiveKitCredentialError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = GetTokenRequest(
            roomId: roomID,
            openidToken: openIDToken,
            member: .init(id: "\(userID):\(deviceID)", claimedUserId: userID, claimedDeviceId: deviceID)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LiveKitCredentialError.tokenExchangeFailed
        }
        let decoded = try JSONDecoder().decode(LiveKitTokenResponse.self, from: data)
        logger.info("LiveKit credentials obtained via /get_token")
        return (decoded.url, decoded.jwt)
    }

    private func fetchLiveKitTokenLegacy(
        sfuURL: String,
        roomID: String,
        openIDToken: OpenIDTokenPayload
    ) async throws -> (url: String, token: String) {
        let base = sfuURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(base)/sfu/get") else {
            throw LiveKitCredentialError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = SFUGetRequest(room: roomID, openidToken: openIDToken, deviceId: deviceID)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LiveKitCredentialError.tokenExchangeFailed
        }
        let decoded = try JSONDecoder().decode(LiveKitTokenResponse.self, from: data)
        logger.info("LiveKit credentials obtained via legacy /sfu/get")
        return (decoded.url, decoded.jwt)
    }
}

// MARK: - Errors

enum LiveKitCredentialError: LocalizedError {
    case sfuURLNotFound
    case invalidURL
    case serverError
    case openIDTokenFailed
    case tokenExchangeFailed

    var errorDescription: String? {
        switch self {
        case .sfuURLNotFound:
            return "This homeserver has no LiveKit call server configured. " +
                   "Check that your server supports MatrixRTC (MSC4143)."
        case .invalidURL:
            return "Could not construct a valid URL for the call server."
        case .serverError:
            return "The homeserver returned an error while fetching call credentials."
        case .openIDTokenFailed:
            return "Failed to obtain an OpenID token from the homeserver."
        case .tokenExchangeFailed:
            return "The call server rejected the credential exchange."
        }
    }
}

// MARK: - Codable Types

private struct RTCTransportsResponse: Decodable {
    let transports: [Transport]
    struct Transport: Decodable {
        let type: String
        let livekitServiceUrl: String
        enum CodingKeys: String, CodingKey {
            case type
            case livekitServiceUrl = "livekit_service_url"
        }
    }
}

private struct WellKnownResponse: Decodable {
    let rtcFoci: [RtcFocus]?
    struct RtcFocus: Decodable {
        let type: String
        let livekitServiceUrl: String
        enum CodingKeys: String, CodingKey {
            case type
            case livekitServiceUrl = "livekit_service_url"
        }
    }
    enum CodingKeys: String, CodingKey {
        case rtcFoci = "org.matrix.msc4143.rtc_foci"
    }
}

// Internal type — not exposed outside RelayKit.
struct OpenIDTokenPayload: Codable {
    let accessToken: String
    let tokenType: String
    let matrixServerName: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case matrixServerName = "matrix_server_name"
        case expiresIn = "expires_in"
    }
}

private struct GetTokenRequest: Encodable {
    let roomId: String
    let openidToken: OpenIDTokenPayload
    let member: Member
    struct Member: Encodable {
        let id: String
        let claimedUserId: String
        let claimedDeviceId: String
        enum CodingKeys: String, CodingKey {
            case id
            case claimedUserId = "claimed_user_id"
            case claimedDeviceId = "claimed_device_id"
        }
    }
    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case openidToken = "openid_token"
        case member
    }
}

private struct SFUGetRequest: Encodable {
    let room: String
    let openidToken: OpenIDTokenPayload
    let deviceId: String
    enum CodingKeys: String, CodingKey {
        case room
        case openidToken = "openid_token"
        case deviceId = "device_id"
    }
}

private struct LiveKitTokenResponse: Decodable {
    let url: String
    let jwt: String
}
