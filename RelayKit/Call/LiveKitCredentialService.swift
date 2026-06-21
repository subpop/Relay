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
import RelayInterface

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
    /// The Matrix server name (e.g. `fedora.im`) extracted from the user ID.
    /// Used for `.well-known` lookups, which must query the server name domain,
    /// not the delegated homeserver URL (e.g. `fedora.ems.host`).
    let serverName: String
    /// Activity log for surfacing credential exchange events in the Activity Log window.
    let activityLog: ActivityLog?

    // MARK: - Public Entry Point

    /// Returns `(livekitWebSocketURL, livekitJWT, sfuServiceURL)` for the given Matrix room.
    /// The `sfuServiceURL` is the SFU service URL from discovery, used in call member events.
    func credentials(for roomID: String) async throws -> (url: String, token: String, sfuServiceURL: String) {
        activityLog?.log(
            category: .call, severity: .info, source: "LiveKitCredentialService",
            summary: "Fetching call credentials",
            detail: "Room: \(roomID)",
            roomId: roomID
        )
        do {
            let sfuURL = try await discoverSFUURL(roomID: roomID)
            activityLog?.log(
                category: .call, severity: .debug, source: "LiveKitCredentialService",
                summary: "SFU URL discovered",
                detail: "SFU: \(sfuURL)",
                roomId: roomID
            )
            let openIDToken = try await requestOpenIDToken()
            activityLog?.log(
                category: .call, severity: .debug, source: "LiveKitCredentialService",
                summary: "OpenID token obtained",
                roomId: roomID
            )
            let (url, jwt) = try await fetchLiveKitToken(sfuURL: sfuURL, roomID: roomID, openIDToken: openIDToken)
            activityLog?.log(
                category: .call, severity: .info, source: "LiveKitCredentialService",
                summary: "Call credentials obtained",
                roomId: roomID
            )
            return (url, jwt, sfuURL)
        } catch {
            activityLog?.log(
                category: .call, severity: .error, source: "LiveKitCredentialService",
                summary: "Failed to fetch call credentials",
                detail: error.localizedDescription,
                roomId: roomID
            )
            throw error
        }
    }

    // MARK: - Step 1: Discover SFU URL

    private func discoverSFUURL(roomID: String) async throws -> String {
        // Existing-call SFU wins. Per `focus_active.focus_selection ==
        // "oldest_membership"` (matrix-js-sdk's `MatrixRTCSession`), every
        // joiner must converge on the SFU advertised by the *oldest*
        // active call membership. If we picked our own homeserver's SFU
        // here instead, a federated call would split across two SFUs and
        // media never reaches the other side.
        if let url = try? await fetchSFUFromCallMembers(roomID: roomID) {
            return url
        }
        // Bootstrap path — we're the first to join. Prefer MSC4143
        // transports endpoint, fall back to `.well-known`.
        if let url = try? await fetchRTCTransportsURL() {
            return url
        }
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
        guard let url = URL(string: "https://\(serverName)/.well-known/matrix/client") else {
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

    /// Reads `m.call.member` state events on the room and returns the
    /// `foci_preferred[].livekit_service_url` advertised by the **oldest**
    /// active call membership — the SFU every joiner is supposed to
    /// converge on per `focus_active.focus_selection == "oldest_membership"`.
    ///
    /// Skips tombstoned (empty-content) and expired memberships so a stale
    /// leftover doesn't outvote the live participants. Returns
    /// `sfuURLNotFound` when nobody is in the call yet, signalling the
    /// caller to bootstrap via local discovery.
    private func fetchSFUFromCallMembers(roomID: String) async throws -> String {
        let base = homeserver.trimmingCharacters(in: .init(charactersIn: "/"))
        let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        guard let url = URL(string: "\(base)/_matrix/client/v3/rooms/\(encodedRoomID)/state") else {
            throw LiveKitCredentialError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LiveKitCredentialError.serverError
        }

        guard let events = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LiveKitCredentialError.sfuURLNotFound
        }

        struct Candidate {
            let createdTs: Int64
            let sfuURL: String
        }
        var candidates: [Candidate] = []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        for event in events {
            guard let type = event["type"] as? String,
                  type == "org.matrix.msc3401.call.member",
                  let content = event["content"] as? [String: Any],
                  !content.isEmpty,
                  let fociPreferred = content["foci_preferred"] as? [[String: Any]],
                  let focus = fociPreferred.first(where: { ($0["type"] as? String) == "livekit" }),
                  let serviceURL = focus["livekit_service_url"] as? String,
                  !serviceURL.isEmpty
            else { continue }

            // Never converge on our OWN membership. We're about to publish a
            // fresh one, and a leftover entry from a previous session (not
            // yet expired/tombstoned) can be the *oldest* — which would make
            // us pick our own homeserver's SFU, momentarily share it with a
            // peer who converged there, then split the call the instant our
            // fresh membership flips the oldest_membership winner to the
            // peer's SFU. `oldest_membership` must be computed over the
            // other participants.
            if (event["sender"] as? String) == userID { continue }

            // Drop expired memberships. Default `expires` is 4h
            // (14400000ms). `created_ts` falls back to event-level
            // `origin_server_ts` so very old non-tombstoned events still
            // get pruned.
            let createdTs = (content["created_ts"] as? NSNumber)?.int64Value
                ?? (event["origin_server_ts"] as? NSNumber)?.int64Value
                ?? 0
            let expires = (content["expires"] as? NSNumber)?.int64Value ?? 14400000
            if createdTs > 0 && createdTs + expires < nowMs {
                continue
            }
            candidates.append(Candidate(createdTs: createdTs, sfuURL: serviceURL))
        }

        guard let oldest = candidates.min(by: { $0.createdTs < $1.createdTs }) else {
            throw LiveKitCredentialError.sfuURLNotFound
        }
        activityLog?.log(
            category: .call, severity: .debug, source: "LiveKitCredentialService",
            summary: "Joining existing call SFU (oldest_membership)",
            detail: "SFU: \(oldest.sfuURL). Picked from \(candidates.count) active member(s)."
        )
        return oldest.sfuURL
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
        // Try legacy `/sfu/get` first. It assigns LiveKit identity
        // `${user}:${device}` — which matches what matrix-js-sdk peers
        // (Element Call / Element X / Element Web) compute as
        // `rtcBackendIdentity` from our `org.matrix.msc3401.call.member`
        // event (see `CallMembership.parseFromEvent` —
        // `MembershipKind.Session` branch is the plain-concat form, not the
        // hashed v2 form). If we use v2 `/get_token` we land on a hashed
        // identity that peers reading our legacy session event cannot
        // reconcile, breaking video routing. v2 only becomes viable once we
        // also publish MSC4143 sticky `m.rtc.member` events.
        do {
            return try await fetchLiveKitTokenLegacy(
                sfuURL: sfuURL,
                roomID: roomID,
                openIDToken: openIDToken
            )
        } catch let legacyError {
            logLegacyFailure(legacyError, sfuURL: sfuURL)
        }
        return try await fetchLiveKitTokenV2(sfuURL: sfuURL, roomID: roomID, openIDToken: openIDToken)
    }

    /// Surfaces a `/sfu/get` failure so the fall-forward to v2 is visible
    /// after the fact. Format-aware: a
    /// `LiveKitCredentialError.tokenExchangeRejected` carries structured
    /// detail; anything else falls through to its `localizedDescription`.
    private func logLegacyFailure(_ error: Error, sfuURL: String) {
        let detail: String
        if case let LiveKitCredentialError.tokenExchangeRejected(status, errcode, message, _) = error {
            let errcodePart = errcode.map { " \($0)" } ?? ""
            let messagePart = message.map { ": \($0)" } ?? ""
            detail = "HTTP \(status)\(errcodePart)\(messagePart)"
        } else {
            detail = error.localizedDescription
        }
        activityLog?.log(
            category: .call, severity: .warning, source: "LiveKitCredentialService",
            summary: "Legacy /sfu/get rejected; trying v2",
            detail: detail
        )
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
            // Element Call hardcodes "m.call#ROOM" for the application slot
            // on the v2 endpoint. lk-jwt-service `SFURequest.Validate()`
            // rejects requests where `slot_id` is empty with HTTP 400
            // M_BAD_JSON, which is what forced every previous Relay call
            // to silently fall back to legacy `/sfu/get`.
            slotId: "m.call#ROOM",
            openidToken: openIDToken,
            member: .init(id: "\(userID):\(deviceID)", claimedUserId: userID, claimedDeviceId: deviceID)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LiveKitCredentialError.serverError
        }
        guard http.statusCode == 200 else {
            let (errcode, message) = Self.parseMatrixError(data)
            throw LiveKitCredentialError.tokenExchangeRejected(
                status: http.statusCode,
                errcode: errcode,
                message: message,
                endpoint: "/get_token"
            )
        }
        let decoded = try JSONDecoder().decode(LiveKitTokenResponse.self, from: data)
        activityLog?.log(
            category: .call, severity: .debug, source: "LiveKitCredentialService",
            summary: "Credentials obtained via v2 /get_token",
            detail: "LiveKit URL: \(decoded.url)",
            roomId: roomID
        )
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
        guard let http = response as? HTTPURLResponse else {
            throw LiveKitCredentialError.serverError
        }
        guard http.statusCode == 200 else {
            let (errcode, message) = Self.parseMatrixError(data)
            throw LiveKitCredentialError.tokenExchangeRejected(
                status: http.statusCode,
                errcode: errcode,
                message: message,
                endpoint: "/sfu/get"
            )
        }
        let decoded = try JSONDecoder().decode(LiveKitTokenResponse.self, from: data)
        activityLog?.log(
            category: .call, severity: .debug, source: "LiveKitCredentialService",
            summary: "Credentials obtained via legacy /sfu/get",
            detail: "LiveKit URL: \(decoded.url)",
            roomId: roomID
        )
        return (decoded.url, decoded.jwt)
    }

    /// Extracts `(errcode, error)` from a Matrix-style error response body.
    /// Used to turn lk-jwt-service responses like
    /// `{"errcode":"M_BAD_JSON","error":"The request body is missing..."}`
    /// into a single human-readable line. Returns `(nil, nil)` if the body
    /// isn't a Matrix error envelope.
    private static func parseMatrixError(_ data: Data) -> (errcode: String?, message: String?) {
        struct MatrixError: Decodable {
            let errcode: String?
            let error: String?
        }
        guard let parsed = try? JSONDecoder().decode(MatrixError.self, from: data) else {
            return (nil, nil)
        }
        return (parsed.errcode, parsed.error)
    }
}

// MARK: - Errors

enum LiveKitCredentialError: LocalizedError {
    case sfuURLNotFound
    case invalidURL
    case serverError
    case openIDTokenFailed
    /// The LiveKit JWT service rejected our request. Carries the HTTP
    /// status, Matrix `errcode`/`error` if present, and which endpoint
    /// produced the failure (`/get_token` or `/sfu/get`) so a user
    /// support trace can identify both the path taken and the reason.
    case tokenExchangeRejected(status: Int, errcode: String?, message: String?, endpoint: String)

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
        case .tokenExchangeRejected(let status, let errcode, let message, let endpoint):
            let errcodePart = errcode.map { " \($0)" } ?? ""
            let messagePart = message.map { ": \($0)" } ?? ""
            return "Call server rejected \(endpoint) with HTTP \(status)\(errcodePart)\(messagePart)"
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
    let slotId: String
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
        case slotId = "slot_id"
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
