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

import AppKit
import Foundation
import MatrixKit
import MatrixKitCrypto
import MatrixKitSwiftData
import MatrixRTC
import Network
import Observation
import OSLog
import RelayShared
import UserNotifications

private nonisolated let relayClientLogger = Logger(
    subsystem: "app.subpop.Relay", category: "RelayClient")

/// The central client coordinator, replacing `MatrixService`.
///
/// ``RelayClient`` owns the MatrixKit `MatrixClient` lifecycle (session
/// restore, login, sync, logout), persists sessions in the keychain,
/// caches snapshots in SwiftData, tracks connectivity, and fans
/// verification-request events out to the UI. Views observe it directly
/// through `@Environment(RelayClient.self)`.
@Observable
final class RelayClient {
    /// The authentication state of the Matrix client.
    enum AuthState: Equatable {
        /// The session state has not yet been determined (app just launched).
        case unknown
        /// No active session; the user needs to sign in.
        case loggedOut
        /// A login attempt is currently in progress.
        case loggingIn
        /// The user is authenticated (associated Matrix user ID).
        case loggedIn(userId: String)
        /// Authentication failed (human-readable error message).
        case error(String)
    }

    /// The synchronization state of the Matrix client.
    enum SyncState: Equatable {
        /// Sync has not been started.
        case idle
        /// The initial sync is in progress.
        case syncing
        /// Sync is running and receiving updates.
        case running
        /// No network connectivity; cached data remains available.
        case offline
        /// Sync encountered an error and stopped.
        case error(String)
    }

    /// Rolling sync statistics for the Activity window.
    ///
    /// Fed by the live delta monitor (`handleSyncDelta`); samples age
    /// out after ten minutes so `rates()` and `buckets()` reflect
    /// recent traffic.
    struct SyncStats {
        /// How long per-delta samples are kept.
        static let sampleRetention: TimeInterval = 600

        /// One sync round-trip's contribution to the rolling window.
        struct Sample {
            var date: Date
            var deltas: Int
            var events: Int
        }

        /// Sync traffic within one minute, for the activity chart.
        struct MinuteBucket {
            /// The minute this bucket starts at, truncated to the minute.
            var start: Date
            var deltas: Int
            var events: Int
        }

        /// When the last live delta arrived.
        var lastSyncAt: Date?
        /// Live deltas seen since session start.
        var totalDeltas = 0
        /// Timeline events carried by those deltas.
        var totalTimelineEvents = 0
        /// To-device messages carried by those deltas.
        var totalToDeviceEvents = 0
        /// Server-reported remaining one-time keys, if ever advertised.
        var lastOneTimeKeyCount: Int?
        /// The most recent sync failure message, if any.
        var lastSyncError: String?
        /// When that failure happened.
        var lastSyncErrorAt: Date?
        /// Per-delta samples for rate computation (pruned to six minutes).
        var samples: [Sample] = []

        /// Record one live delta.
        mutating func record(delta: SyncDelta, at date: Date = Date()) {
            totalDeltas += 1
            let eventCount = delta.joined.values.reduce(0) { $0 + $1.timeline.count }
            totalTimelineEvents += eventCount
            totalToDeviceEvents += delta.toDevice.count
            if let count = delta.signedKeyCount {
                lastOneTimeKeyCount = count
            }
            lastSyncAt = date
            samples.append(Sample(date: date, deltas: 1, events: eventCount))
            let cutoff = date.addingTimeInterval(-Self.sampleRetention)
            samples.removeAll { $0.date < cutoff }
        }

        /// Record a sync failure.
        mutating func recordError(_ message: String, at date: Date = Date()) {
            lastSyncError = message
            lastSyncErrorAt = date
        }

        /// Deltas and timeline events per minute over the trailing window.
        func rates(window: TimeInterval = 300, now: Date = Date()) -> (
            deltasPerMinute: Double, eventsPerMinute: Double
        ) {
            let cutoff = now.addingTimeInterval(-window)
            let recent = samples.filter { $0.date >= cutoff }
            guard let oldest = recent.map(\.date).min() else { return (0, 0) }
            let minutes = max(now.timeIntervalSince(oldest), 1) / 60
            let deltas = recent.reduce(0) { $0 + $1.deltas }
            let events = recent.reduce(0) { $0 + $1.events }
            return (Double(deltas) / minutes, Double(events) / minutes)
        }

        /// Clear all counters (session teardown).
        mutating func reset() {
            self = SyncStats()
        }

        /// Aggregate samples into per-minute buckets covering the trailing
        /// `minutes` minutes (including empty minutes), oldest first.
        func buckets(minutes: Int = 10, now: Date = Date()) -> [MinuteBucket] {
            guard minutes > 0 else { return [] }
            let minute: TimeInterval = 60
            let reference = now.timeIntervalSinceReferenceDate
            let currentStart = Date(
                timeIntervalSinceReferenceDate: floor(reference / minute) * minute)
            var buckets = (0..<minutes).map { offset in
                MinuteBucket(
                    start: currentStart.addingTimeInterval(
                        -minute * Double(minutes - 1 - offset)),
                    deltas: 0,
                    events: 0)
            }
            let windowStart = buckets[0].start.timeIntervalSinceReferenceDate
            for sample in samples {
                let index = Int(floor(
                    (sample.date.timeIntervalSinceReferenceDate - windowStart) / minute))
                guard buckets.indices.contains(index) else { continue }
                buckets[index].deltas += sample.deltas
                buckets[index].events += sample.events
            }
            return buckets
        }
    }

    /// A notable session moment for the Activity window feed (oldest first).
    struct ActivityEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        /// One-line description (e.g. "Initial sync completed").
        let text: String
    }

    /// An incoming session verification request from another device.
    struct IncomingVerification: Identifiable, Equatable {
        /// The flow identifier for the verification request.
        let flowId: String
        /// The device ID that initiated the request.
        let deviceId: String
        /// The Matrix user ID of the sender.
        let senderId: String

        var id: String { flowId }
    }

    /// A room message that passed notification filtering, ready for a
    /// local banner. Produced by the sync-delta monitor.
    struct RoomMessageNotification: Sendable {
        /// The notified event's ID (notification request identifier).
        let eventId: String
        /// The room's ID (thread identifier and tap-navigation payload).
        let roomId: String
        /// The room's display name.
        let roomName: String
        /// The sender's display name, if known.
        let authorName: String?
        /// The message body.
        let body: String
        /// Whether the message mentions the local user.
        let isMention: Bool
        /// Whether the room is a direct chat.
        let isDirect: Bool
    }

    /// What the verification sheet should show after a successful
    /// self-verification handshake.
    enum SelfVerifyCompletion: Sendable {
        /// Trust is established; the flow is done.
        case verified
        /// Secrets were requested; the user must approve sharing on
        /// the peer device before trust is established.
        case waitingForKeyShare
    }

    /// Persisted session blob.
    private struct StoredSession: Codable {
        var homeserver: String
        var userId: String
        var deviceId: String
        var accessToken: String
        var refreshToken: String?
        var oidcClientId: String?
        var oidcTokenEndpoint: String?
    }

    private static let sessionService = "session"
    private static let sessionAccount = "matrix-session"

    /// UserDefaults key for the Labs sliding-sync experiment.
    static let slidingSyncLabsKey = "labs.slidingSync"

    var authState: AuthState = .unknown
    var syncState: SyncState = .idle
    var hasLoadedRooms = false
    var isNetworkConnected = true
    var isSessionVerified = false
    var hasCheckedVerificationState = false
    var pendingVerificationRequest: IncomingVerification?
    /// An accepted incoming verification session awaiting its sheet.
    /// Consumed by the sheet presentation; the handshake continues there.
    var activeVerificationSession: VerificationSession?
    var shouldPresentVerificationSheet = false
    var pendingDeepLink: MatrixURI?
    /// Rolling sync statistics, fed by the live delta monitor.
    var syncStats = SyncStats()
    /// Notable session moments (oldest first, capped), for the Activity window.
    var recentActivity: [ActivityEntry] = []
    /// When the current session was adopted (login or restore). Nil when logged out.
    var sessionStartedAt: Date?
    let errorReporter = ErrorReporter()
    /// Background key-backup restores with progress + cancellation.
    /// Set in `init`, after the observers that capture `self`.
    var keyFetch: KeyFetchCoordinator!

    /// Cached effective notification modes by room ID, refreshed after
    /// sync. Drives mute badges, row sorting, and the dock badge without
    /// per-render network calls.
    var notificationModeCache: [String: MatrixKit.RoomNotificationMode] = [:]

    /// Set when the homeserver rejects our access token (`M_UNKNOWN_TOKEN`),
    /// meaning the session was signed out remotely (e.g. from the
    /// homeserver's session management page). Drives the blocking
    /// "Session Signed Out" alert in `ContentView`. Cleared on the next
    /// login or logout.
    var remoteSignOutNoticed = false

    /// Cached highlight keywords from push rules (fed to timelines).
    var notificationKeywords: [String] = []

    /// Joined rooms (refresh-driven by the sync engine).
    var rooms: [ObservableRoom] {
        client?.roomList.joined ?? []
    }

    /// Joined top-level spaces for the space rail.
    var spaces: [ObservableRoom] {
        rooms.filter { $0.isSpace && $0.membership == .join && $0.successorRoomId == nil }
    }

    /// Pending invites.
    var invitedRooms: [ObservableRoom] {
        client?.roomList.invited ?? []
    }

    /// Whether the Labs sliding-sync experiment is enabled.
    var isSlidingSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.slidingSyncLabsKey)
    }

    /// Whether the homeserver is known to support simplified sliding
    /// sync. Optimistic when logged out or versions are unknown,
    /// matching `MatrixClient.canUseSlidingSync`.
    var canUseSlidingSync: Bool {
        client?.canUseSlidingSync ?? true
    }

    /// Which loop the live sync is running on.
    var isUsingSlidingSync: Bool { usingSlidingSync }

    /// Sliding-sync support as the server advertised it. Nil when the
    /// versions fetch never succeeded (e.g. offline at startup).
    var serverSupportsSlidingSync: Bool? {
        guard let client, client.serverVersions != nil else { return nil }
        return client.canUseSlidingSync
    }

    /// Newest spec version advertised by the homeserver (e.g. "v1.15").
    /// Nil when the versions fetch never succeeded.
    var newestServerVersion: String? {
        client?.serverVersions?.versions.max(by: {
            Self.compareSpecVersion($0, $1) == .orderedAscending
        })
    }

    /// Whether the client is actively syncing.
    var isSyncing: Bool {
        syncState == .syncing || syncState == .running
    }

    private var client: MatrixClient?
    private let keychain = KeychainKeyStore()
    private var syncTask: Task<Void, Never>?
    /// Watchdog for silent sync-loop death (see `startSyncWatchLoop`).
    private var syncWatchTask: Task<Void, Never>?
    /// True while a stop/restart we initiated is in flight, so the sync
    /// liveness watcher doesn't mistake our own teardown for a dead session.
    private var syncStopRequested = false
    /// Which loop `startSyncLoop` started last (sliding vs. classic),
    /// so preference changes can restart only on a real mode switch.
    private var usingSlidingSync = false
    private var verificationTask: Task<Void, Never>?
    private var secretsTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Watches the room list for the share-extension room cache.
    private var shareCacheWatchTask: Task<Void, Never>?
    /// Debounces share-cache writes during sync bursts.
    private var shareCacheDebounceTask: Task<Void, Never>?
    /// Live `notificationEvents()` subscribers.
    private var notificationContinuations: [AsyncStream<RoomMessageNotification>.Continuation] = []
    /// Newest notified event timestamp (ms) per room ID. Dedupes sync
    /// replays (e.g. limited-timeline gaps after reconnects).
    private var lastNotifiedEventTimestamp: [String: Int] = [:]
    /// Pending invites already logged. The server repeats invites in every
    /// sync until resolved; without this each would log once per sync.
    private var loggedInviteRoomIds: Set<String> = []
    /// Left rooms already recorded in the activity feed (same repeat issue).
    private var loggedLeftRoomIds: Set<String> = []
    private let avatarCache = NSCache<NSString, NSImage>()
    private let intentDonation = IntentDonationService()
    private var monitor: NWPathMonitor?
    /// Gates `startSyncIfNeeded` until the adopt flow has restored the
    /// snapshot and run its first sync. The path monitor fires
    /// immediately on install (before restore), and starting the live
    /// loop tokenless forces a wasteful full initial sync that visibly
    /// reconverges every badge. The flow's own `startSyncLoop()` is the
    /// backstop, so skipping early monitor starts loses nothing.
    private var didFinishStartupSync = false
    /// Retained block observers (app lifecycle → cache saves).
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Next allowed background save: app switches can come seconds
    /// apart; snapshots are cheap to capture but rewrite the store.
    private var earliestNextBackgroundSave = Date.distantPast

    init() {
        avatarCache.countLimit = 500
        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.saveCacheThrottled() } },
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.saveCache()
                        // Best effort: settle any debounced crypto
                        // writes so a quit inside the loss window
                        // cannot drop ratchet state.
                        Task { await self?.flushCryptoState() }
                    } },
            // The Labs sliding-sync toggle writes UserDefaults directly;
            // restart the loop when the preference changes mid-session.
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applySyncModePreference() } },
        ]
        // Assigned last: the closures capture `self`, which requires
        // every other stored property to be initialized first.
        keyFetch = KeyFetchCoordinator(
            restore: { [weak self] key, progress in
                guard let self else { throw RelayError.notLoggedIn }
                return try await self.restoreKeyBackup(
                    privateKey: key, progress: progress)
            },
            report: { [weak self] error in
                self?.errorReporter.report(error)
            })
    }

    // MARK: - Session

    /// Restore a previously saved session from the keychain, if any.
    ///
    /// Never runs in Xcode previews: restoring would adopt (and sync)
    /// the user's live account inside the canvas.
    func restoreSession() async {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            return
        }
        let sessionKey = KeyStoreKey(
            service: Self.sessionService, account: Self.sessionAccount)
        let data: Data?
        do {
            data = try await keychain.load(sessionKey)
        } catch {
            relayClientLogger.error(
                "Saved session unreadable (keychain load failed); staying logged out: \(error.localizedDescription, privacy: .public)")
            authState = .loggedOut
            return
        }
        guard let data else {
            relayClientLogger.info("No saved session in keychain")
            authState = .loggedOut
            return
        }
        guard
            let stored = try? JSONDecoder().decode(StoredSession.self, from: data),
            let homeserver = URL(string: stored.homeserver)
        else {
            relayClientLogger.error("Saved session present but undecodable; staying logged out")
            authState = .loggedOut
            return
        }
        let deviceId = DeviceId(stored.deviceId)
        let client = await MatrixClient.restore(
            homeserver: homeserver,
            userId: UserId(unchecked: stored.userId),
            deviceId: deviceId,
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            oidcClientId: stored.oidcClientId,
            oidcTokenEndpoint: stored.oidcTokenEndpoint,
            keystore: keychain)
        // The stored MXID may differ from the server-assigned one (e.g.
        // unqualified at login time); reconcile before adopting so rooms
        // observe the correct local user. Persist the reconciled ID so the
        // keychain always holds the fully-qualified MXID. A failed whoami
        // (e.g. offline) keeps the stored identity rather than logging out.
        do {
            try await client.reconcileIdentity()
            await persistSessionLoudly(for: client, context: "reconcile")
        } catch {
            relayClientLogger.warning(
                "Identity reconciliation failed, using stored user ID: \(error.localizedDescription, privacy: .public)")
        }
        await adopt(client: client, userId: client.userId?.value ?? stored.userId)
    }

    /// Log in with username and password.
    func login(username: String, password: String, homeserver: String) async {
        authState = .loggingIn
        do {
            let url = try homeserverURL(homeserver)
            let client = try await MatrixClient.login(
                homeserver: url,
                user: username,
                password: password,
                deviceDisplayName: "Relay (macOS)",
                keystore: keychain)
            guard let userId = client.userId?.value else {
                authState = .error("Sign in succeeded without a user ID.")
                return
            }
            try await persistSession(for: client)
            relayClientLogger.info("Signed in as \(userId, privacy: .public)")
            await adopt(client: client, userId: userId)
        } catch {
            relayClientLogger.error(
                "Sign-in failed: \(error.localizedDescription, privacy: .public)")
            authState = .error(error.localizedDescription)
        }
    }

    /// Browser-based OIDC login. `openURL` opens the authorization URL
    /// and returns the callback URL (e.g. via `WebAuthenticationSession`).
    func startOAuthLogin(
        homeserver: String,
        openURL: @escaping @Sendable (URL) async throws -> URL
    ) async throws {
        let url = try homeserverURL(homeserver)
        let pending = try await MatrixClient.prepareOIDCBrowserLogin(
            homeserver: url, clientName: "Relay",
            clientURI: "https://subpop.github.io/Relay",
            logoURI: "https://subpop.github.io/Relay/logo-256.png",
            redirectURI: "io.github.subpop.relay:/")
        let callback = try await openURL(pending.authorizationURL)
        guard
            let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        else {
            throw RelayError.oauthInvalidURL
        }
        let client = try await MatrixClient.completeOIDCBrowserLogin(
            pending, code: code, state: state, keystore: keychain)
        guard let userId = client.userId?.value else {
            throw RelayError.oauthInvalidURL
        }
        try await persistSession(for: client)
        await adopt(client: client, userId: userId)
    }

    /// Sign out and clear the saved session.
    ///
    /// UI state flips first so logout feels instant; server invalidation,
    /// the local crypto wipe, and the keychain wipe follow best-effort
    /// (any can stall on a dead network or expired tokens, which must
    /// not trap the UI). Wiping crypto material (cross-signing backup,
    /// device identities, Olm/megolm sessions) means a fresh sign-in
    /// starts unverified, as users expect.
    ///
    /// Destructive: only call from explicit user action (never from
    /// alert dismissal, teardown, or error paths).
    func logout(reason: String = "explicit") async {
        stopTasks()
        let client = self.client
        self.client = nil
        authState = .loggedOut
        remoteSignOutNoticed = false
        syncState = .idle
        hasLoadedRooms = false
        isSessionVerified = false
        hasCheckedVerificationState = false
        pendingVerificationRequest = nil
        activeVerificationSession = nil
        shouldPresentVerificationSheet = false
        lastNotifiedEventTimestamp = [:]
        syncStats = SyncStats()
        recentActivity = []
        sessionStartedAt = nil
        relayClientLogger.info("Signed out (reason: \(reason, privacy: .public))")
        if let client {
            // Wipe first: `logout()` clears the user ID the wipe needs.
            await client.deleteLocalCryptoMaterial()
            try? await client.logout()
        }
        try? await keychain.delete(KeyStoreKey(
            service: Self.sessionService, account: Self.sessionAccount))
    }

    /// Clear cached data and resync, staying logged in.
    func clearLocalData() async {
        guard let client, let userId = client.userId else { return }
        syncTask?.cancel()
        didFinishStartupSync = false
        try? await cache(for: userId)?.clear()
        syncState = .syncing
        do {
            try await initialSyncRoundTrip()
            saveCache()
            syncState = .running
            await refreshNotificationModes()
            didFinishStartupSync = true
            startSyncLoop()
        } catch {
            relayClientLogger.error(
                "Resync after cache clear failed: \(error.localizedDescription, privacy: .public)")
            if Self.isSessionInvalidation(error) {
                handleRemoteSignOut(softLogout: Self.softLogoutHint(error), source: "cache resync")
            } else {
                syncState = .error(error.localizedDescription)
                syncStats.recordError(error.localizedDescription)
                recordActivity("Resync after cache clear failed")
            }
        }
    }

    /// The current user ID, if logged in.
    func userId() -> String? {
        client?.userId?.value
    }

    // MARK: - Sync

    /// Initial sync round-trip for the active sync mode. The sliding
    /// path passes explicit lists: `slidingSyncOnce` with nil reuses
    /// the engine's stored lists, which are empty before `start`.
    private func initialSyncRoundTrip() async throws {
        guard let client else { return }
        if isSlidingSyncEnabled && client.canUseSlidingSync {
            try await client.slidingSyncOnce(lists: SlidingSyncClient.defaultLists)
        } else {
            try await client.syncOnce(filter: .leanInitial)
        }
    }

    /// Start the background sync loop if it is not already running.
    func startSyncIfNeeded() {
        guard
            client != nil, syncTask == nil, isNetworkConnected,
            didFinishStartupSync
        else { return }
        startSyncLoop()
        if syncState == .idle {
            syncState = .running
        }
    }

    // MARK: - Rooms

    /// Accept a pending invitation.
    func acceptInvite(roomId: String) async throws {
        guard let client else { return }
        // Spec invitee behavior: an invite carrying `is_direct` auto-marks
        // the room in our own `m.direct`. Best effort so a bookkeeping
        // failure can never reject an accepted invite.
        let directInvite: Bool = {
            guard let invited = invitedRooms.first(where: { $0.roomId.value == roomId }),
                let localUser = invited.localUserId
            else { return false }
            return invited.memberDetails[localUser]?.isDirect == true
        }()
        try await client.rooms.join(RoomId(unchecked: roomId))
        if directInvite, let userId = client.userId {
            do {
                try await client.accountData.setDirectRoom(
                    RoomId(unchecked: roomId), for: userId, isDirect: true)
            } catch {
                relayClientLogger.warning(
                    "m.direct auto-mark failed for \(roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Join a room by ID (e.g. an upgrade successor).
    func joinRoom(roomId: String) async throws {
        guard let client else { return }
        try await client.rooms.join(RoomId(unchecked: roomId))
    }

    /// Decline a pending invitation.
    func declineInvite(roomId: String) async throws {
        guard let client else { return }
        try await client.rooms.leave(RoomId(unchecked: roomId))
    }

    /// Leave a room.
    func leaveRoom(id: String) async throws {
        guard let client else { return }
        try await client.rooms.leave(RoomId(unchecked: id))
    }

    /// Pin or unpin a room (`m.favourite` tag).
    func setFavourite(roomId: String, isFavourite: Bool) async throws {
        guard let client else { return }
        try await client.room(RoomId(unchecked: roomId)).setFavourite(isFavourite)
    }

    /// Mark a room read up to its latest message. With `sendReceipt` false
    /// (Send Read Receipts off) a private `m.read.private` receipt is sent
    /// instead of the public `m.read` one: invisible to other members, but
    /// it still clears the server's unread count so badges stay cleared
    /// across restarts and other clients agree. `m.fully_read` advances
    /// either way so the unread divider stays correct. Badges additionally
    /// clear locally via the optimistic marker (see
    /// `displayUnreadCount(for:)`), since sync can lag a send by a
    /// round-trip.
    func markAsRead(roomId: String, sendReceipt: Bool = true) async {
        guard let client else { return }
        let room = await client.room(RoomId(unchecked: roomId))
        // Local echoes (`local:<txn>`) have no server-side event yet, so
        // neither endpoint accepts them — mark up to the newest
        // server-assigned event instead.
        guard let latest = newestServerEvent(in: room) else { return }
        // Skip when the latest event hasn't advanced since the last mark:
        // layout churn (e.g. window resizes) must not re-post. Re-fire only
        // if a room receipt is now requested that wasn't sent before.
        if !Self.shouldSendMark(
            lastMarked: lastMarkedRead[roomId],
            latestEventId: latest.eventId.value,
            sendReceipt: sendReceipt) {
            return
        }
        var receiptSent = false
        do {
            try await room.markRead(latest.eventId, receiptType: Self.receiptType(sendReceipt: sendReceipt))
            receiptSent = true
        } catch {
            relayClientLogger.warning(
                "Read receipt send failed room=\(roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        var fullyReadSent = false
        do {
            try await room.sendFullyRead(latest.eventId)
            fullyReadSent = true
        } catch {
            relayClientLogger.warning(
                "Fully-read marker send failed room=\(roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // Record only on success: a failed mark must stay retryable, or the
        // dedupe above suppresses it until a new message arrives and the
        // room looks stuck unread. `sentReceipt` tracks the *public*
        // receipt only, so flipping Send Read Receipts on re-fires the
        // mark for an event previously cleared privately.
        guard receiptSent || fullyReadSent else { return }
        lastMarkedRead[roomId] = (latest.eventId.value, sendReceipt && receiptSent)
        optimisticReadMarkers[roomId] = latest.eventId.value
        clearDeliveredNotifications(forRoomId: roomId)
    }

    /// Mark every joined room read up to its latest message. Rooms already
    /// read are cheap no-ops via the `markAsRead` dedupe, and per-room
    /// failures are logged-and-continued there so one room never aborts
    /// the sweep.
    func markAllRoomsAsRead(
        sendReceipt: Bool = UserDefaults.standard.object(forKey: "safety.sendReadReceipts") as? Bool ?? true
    ) async {
        for room in rooms {
            await markAsRead(roomId: room.roomId.value, sendReceipt: sendReceipt)
        }
    }

    /// The receipt type for a mark-as-read: public when the user shares
    /// read state, private (same-account, invisible to others) otherwise.
    /// Pure so the selection stays unit-tested.
    static nonisolated func receiptType(sendReceipt: Bool) -> String {
        sendReceipt ? "m.read" : "m.read.private"
    }

    /// Whether a mark-as-read send should fire for `latestEventId`, given
    /// the last successful mark and whether a room receipt is requested.
    /// Pure so the retry/dedupe contract stays unit-tested.
    static nonisolated func shouldSendMark(
        lastMarked: (eventId: String, sentReceipt: Bool)?,
        latestEventId: String,
        sendReceipt: Bool
    ) -> Bool {
        guard let lastMarked else { return true }
        guard lastMarked.eventId == latestEventId else { return true }
        // Same event: re-fire only if a receipt is now requested that
        // wasn't actually sent before (e.g. the earlier receipt failed but
        // fully-read succeeded, or the setting was flipped on).
        return sendReceipt && !lastMarked.sentReceipt
    }

    /// Newest event ID safe to send receipts for, skipping local echoes
    /// (`local:<txn>`), which the receipt/read-marker endpoints reject.
    static nonisolated func newestMarkableEventId(in eventIds: [String]) -> String? {
        eventIds.last(where: isMarkableEventId)
    }

    /// Whether an event ID is safe to send receipts for (i.e. not a local
    /// echo awaiting server confirmation).
    static nonisolated func isMarkableEventId(_ eventId: String) -> Bool {
        !eventId.hasPrefix("local:")
    }

    /// Unread count for display: zero when the room's newest server event
    /// is one this client already marked read (the synced server count may
    /// still be stale). Falls back to the server count when a newer event
    /// arrived or nothing was marked yet.
    func displayUnreadCount(for room: ObservableRoom) -> Int {
        isOptimisticallyRead(room) ? 0 : room.unreadCount
    }

    /// Highlight count for display, with the same optimistic clear as
    /// `displayUnreadCount(for:)`.
    func displayHighlightCount(for room: ObservableRoom) -> Int {
        isOptimisticallyRead(room) ? 0 : room.highlightCount
    }

    /// Whether the room's newest server-assigned event was already marked
    /// read by this client. A pending own echo neither defeats the clear
    /// nor hides genuine unread state: only server-assigned IDs count.
    private func isOptimisticallyRead(_ room: ObservableRoom) -> Bool {
        guard let marker = optimisticReadMarkers[room.roomId.value],
              let newest = newestServerEvent(in: room) else {
            return false
        }
        return newest.eventId.value == marker
    }

    /// The room's newest server-assigned timeline event, if any.
    private func newestServerEvent(in room: ObservableRoom) -> ObservableTimelineEvent? {
        room.timeline?.events.last(where: { Self.isMarkableEventId($0.eventId.value) })
    }

    /// Remove this room's delivered message banners now that it reads as
    /// read. Best-effort: notification removal never fails a mark.
    private func clearDeliveredNotifications(forRoomId roomId: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            let identifiers = await center.deliveredNotifications()
                .filter { $0.request.content.userInfo["roomId"] as? String == roomId }
                .map(\.request.identifier)
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// Download media bytes: memory callers go through the disk cache
    /// first, so pruned server media still resolves when previously
    /// fetched. Returns nil on failure (logged once per MXC).
    func downloadMedia(mxcURL: String) async -> Data? {
        if let hit = await MediaDiskCache.shared.read(key: mxcURL) {
            return hit
        }
        guard let client, let uri = try? MXCURI(mxcURL) else { return nil }
        do {
            let data = try await client.media.download(uri)
            await MediaDiskCache.shared.write(key: mxcURL, data: data)
            return data
        } catch {
            logMediaFailure("download", mxcURL: mxcURL, error: error)
            return nil
        }
    }

    /// Download and decrypt an encrypted file, or nil on failure.
    func downloadDecryptedMedia(file: EncryptedFile) async -> Data? {
        if let hit = await MediaDiskCache.shared.read(key: file.url) {
            return hit
        }
        guard let client else { return nil }
        do {
            let data = try await client.media.downloadDecrypted(file)
            await MediaDiskCache.shared.write(key: file.url, data: data)
            return data
        } catch {
            logMediaFailure("decrypted-download", mxcURL: file.url, error: error)
            return nil
        }
    }

    /// Deduplicated debug logging for media failures (scrolling would
    /// otherwise spam one entry per row appearance).
    private var loggedMediaFailures = Set<String>()

    /// Newest event ID already marked read per room (plus whether the
    /// *public* room receipt was sent), so repeat triggers without new
    /// messages post nothing. Recorded only on success so failed marks
    /// stay retryable.
    private var lastMarkedRead: [String: (eventId: String, sentReceipt: Bool)] = [:]

    /// Newest event ID successfully marked read per room. Sync can lag a
    /// read send by a round-trip, so display sites clear badges locally
    /// until a newer event arrives.
    private var optimisticReadMarkers: [String: String] = [:]

    private func logMediaFailure(_ operation: String, mxcURL: String, error: Error) {
        let key = "\(operation):\(mxcURL)"
        guard !loggedMediaFailures.contains(key) else { return }
        loggedMediaFailures.insert(key)
        Task {
            relayClientLogger.debug(
                "Media \(operation, privacy: .public) failed for \(mxcURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Download the full bytes for a timeline attachment, decrypting when
    /// the event carries an encrypted file reference.
    func mediaBytes(_ download: MediaFileHelper.Download) async -> Data? {
        if let encrypted = download.encryptedFile {
            return await downloadDecryptedMedia(file: encrypted)
        }
        return await downloadMedia(mxcURL: download.mxcURL)
    }

    /// Download a thumbnail for a timeline attachment. Prefers the
    /// server-generated thumbnail (decrypting it when the metadata carries
    /// an encrypted thumbnail reference), falling back to a
    /// server-side-scaled thumbnail of the full content, and finally to
    /// the full decrypted bytes (which the caller downscales by display).
    /// The last fallback is what makes encrypted attachments without a
    /// separate encrypted thumbnail render at all.
    func mediaThumbnail(
        _ download: MediaFileHelper.Download, width: UInt64, height: UInt64
    ) async -> Data? {
        let cacheKey = "\(download.mxcURL)_thumb_\(width)x\(height)"
        if let hit = await MediaDiskCache.shared.read(key: cacheKey) {
            return hit
        }
        guard let client else { return nil }
        if let encrypted = download.encryptedThumbnail {
            guard let uri = try? MXCURI(encrypted.url) else { return nil }
            guard let raw = try? await client.media.download(uri) else { return nil }
            if let decrypted = try? MediaClient.decryptFile(raw, file: encrypted) {
                await MediaDiskCache.shared.write(key: cacheKey, data: decrypted)
                return decrypted
            }
        }
        let thumbMXC = download.thumbnailMXCURL ?? download.mxcURL
        if let uri = try? MXCURI(thumbMXC),
           let data = try? await client.media.thumbnail(
               uri, width: Int(width), height: Int(height)),
           !data.isEmpty, NSImage(data: data) != nil {
            await MediaDiskCache.shared.write(key: cacheKey, data: data)
            return data
        }
        return await mediaBytes(download)
    }

    /// Make a timeline view model for a room, or nil when unknown.
    func makeTimelineViewModel(roomId: String) async -> TimelineViewModel? {
        guard let client else { return nil }
        let room = await client.room(RoomId(unchecked: roomId))
        return TimelineViewModel(
            room: room,
            highlights: notificationKeywords,
            errorReporter: errorReporter)
    }

    /// Download (and cache) an avatar thumbnail, falling back to the
    /// full image when the server has no thumbnail for the MXC.
    func avatarThumbnail(mxcURL: String, size: CGFloat) async -> NSImage? {
        let key = "\(mxcURL)-\(Int(size))" as NSString
        if let cached = avatarCache.object(forKey: key) {
            return cached
        }
        // Disk keys embed the requested pixel size, so probe the exact
        // key first, then other cached sizes largest-first: a downscaled
        // larger thumbnail beats initials whenever the server copy is gone.
        let px = UInt64(size * 2)
        for probe in Self.thumbnailProbeSizes(px: px) {
            let diskKey = "\(mxcURL)_\(probe)"
            if let data = await MediaDiskCache.shared.read(key: diskKey),
                let image = NSImage(data: data) {
                avatarCache.setObject(image, forKey: key)
                return image
            }
        }
        guard let client, let uri = try? MXCURI(mxcURL) else { return nil }
        let pixels = Int(size * 2)
        let diskKey = "\(mxcURL)_\(px)"
        if let data = try? await client.media.thumbnail(
            uri, width: pixels, height: pixels),
            let image = NSImage(data: data) {
            avatarCache.setObject(image, forKey: key)
            await MediaDiskCache.shared.write(key: diskKey, data: data)
            return image
        }
        guard let data = await downloadMedia(mxcURL: mxcURL),
              let image = NSImage(data: data) else {
            logMediaFailure(
                "avatar-thumbnail", mxcURL: mxcURL,
                error: MediaFileHelper.MediaFileError.downloadFailed)
            return nil
        }
        avatarCache.setObject(image, forKey: key)
        await MediaDiskCache.shared.write(key: diskKey, data: data)
        return image
    }

    /// Thumbnail pixel sizes to probe, exact size first then
    /// largest-first fallbacks.
    private static func thumbnailProbeSizes(px: UInt64) -> [UInt64] {
        [px]
            + [320, 256, 192, 160, 144, 128, 120, 96, 80, 72, 64, 56, 48, 32]
            .filter { $0 != px }
    }

    /// Avatar bytes for the share-extension room cache, read straight
    /// from the media disk cache without decoding. The sweep runs on
    /// every room-list change, so routing through `avatarThumbnail`
    /// would inflate every avatar into an NSImage (plus an uncompressed
    /// TIFF) on each pass. Only a disk miss falls back to the download
    /// path, which repopulates the disk cache for later sweeps.
    private func shareCacheAvatarData(mxcURL: String, size: CGFloat) async -> Data? {
        let px = UInt64(size * 2)
        for probe in Self.thumbnailProbeSizes(px: px) {
            if let data = await MediaDiskCache.shared.read(
                key: "\(mxcURL)_\(probe)")
            {
                return data
            }
        }
        guard let image = await avatarThumbnail(mxcURL: mxcURL, size: size) else {
            return nil
        }
        return image.tiffRepresentation
    }

    /// Effective notification mode for a room (override or type default).
    func effectiveNotificationMode(for room: ObservableRoom) async -> MatrixKit.RoomNotificationMode {
        if let cached = notificationModeCache[room.roomId.value] {
            return cached
        }
        guard let client else { return .mentionsAndKeywordsOnly }
        if let override = try? await client.notifications.getRoomNotificationMode(
            roomId: room.roomId)
        {
            notificationModeCache[room.roomId.value] = override
            return override
        }
        let isOneToOne = room.presentsAsDirect
        guard
            let mode = try? await client.notifications.getDefaultNotificationMode(
                isOneToOne: isOneToOne)
        else {
            return isOneToOne ? .allMessages : .mentionsAndKeywordsOnly
        }
        let mapped: MatrixKit.RoomNotificationMode
        switch mode {
        case .allMessages: mapped = .allMessages
        case .mentionsAndKeywordsOnly: mapped = .mentionsAndKeywordsOnly
        case .mute: mapped = .mute
        }
        notificationModeCache[room.roomId.value] = mapped
        return mapped
    }

    /// Whether a room is muted (cached mode).
    func isMuted(roomId: String) -> Bool {
        notificationModeCache[roomId] == .mute
    }

    /// The cached per-room notification mode, if an override is known.
    func notificationMode(roomId: String) -> RoomNotificationMode? {
        notificationModeCache[roomId]
    }

    /// Refresh notification modes (defaults plus per-room overrides)
    /// and highlight keywords.
    func refreshNotificationModes() async {
        guard let client else { return }
        notificationKeywords = (try? await client.notifications.getNotificationKeywords()) ?? []
        let customs: Set<RoomId>
        do {
            customs = Set(try await client.notifications.roomsWithCustomNotificationSettings())
        } catch {
            relayClientLogger.warning(
                "Push-rules fetch failed; falling back to defaults: \(error.localizedDescription, privacy: .public)")
            customs = []
        }
        for room in rooms {
            if customs.contains(room.roomId) {
                do {
                    if let override = try await client.notifications.getRoomNotificationMode(
                        roomId: room.roomId)
                    {
                        notificationModeCache[room.roomId.value] = override
                        continue
                    }
                } catch {
                    relayClientLogger.warning(
                        "Room mode fetch failed for \(room.roomId.value, privacy: .public); falling back to default: \(error.localizedDescription, privacy: .public)")
                }
            }
            notificationModeCache[room.roomId.value] = await effectiveDefault(for: room)
        }
    }

    private func effectiveDefault(for room: ObservableRoom) async -> MatrixKit.RoomNotificationMode {
        guard let client else { return .mentionsAndKeywordsOnly }
        let isOneToOne = room.presentsAsDirect
        guard
            let mode = try? await client.notifications.getDefaultNotificationMode(
                isOneToOne: isOneToOne)
        else {
            return isOneToOne ? .allMessages : .mentionsAndKeywordsOnly
        }
        switch mode {
        case .allMessages: return .allMessages
        case .mentionsAndKeywordsOnly: return .mentionsAndKeywordsOnly
        case .mute: return .mute
        }
    }

    // MARK: - Encryption Bootstrap

    /// Publish this session's device keys and one-time keys.
    ///
    /// Restores the persisted device identity (or generates and stores a
    /// fresh one), uploads the device keys (`/keys/upload`), then brings
    /// up Olm key exchange on the same identity. Mirrors the `mx` CLI's
    /// `ensureDeviceIdentity` startup sequence. Throws so callers can
    /// decide how to surface failures; without it, peers cannot resolve
    /// this device's keys and verification requests go unanswered.
    static func bootstrapEncryption(
        on client: MatrixClient, keystore: (any KeyStore)? = nil
    ) async throws {
        guard let userId = client.userId, let deviceId = client.deviceId
        else {
            throw RelayError.sessionsFailed(
                "Encryption bootstrap: missing session.")
        }
        let store = DeviceIdentityStore(keystore: keystore)
        let identity = DeviceIdentity(
            transport: client.transport, session: client.session)
        if let backup = await store.load(userId: userId, deviceId: deviceId) {
            try await identity.restore(backup)
        } else {
            await identity.generate()
            if let backup = await identity.backup() {
                try await store.save(backup, userId: userId, deviceId: deviceId)
            }
        }
        try await identity.upload()
        if let backup = await identity.backup() {
            let material = try DeviceIdentityKeys.restore(backup)
            try await client.olm.configure(
                identity: material, userId: userId, deviceId: deviceId)
            try await client.olm.ensureKeys()
        }
    }

    // MARK: - Verification

    /// Refresh cross-signing verification state.
    func refreshVerificationState() async {
        guard let client else { return }
        await client.refreshVerificationState()
        isSessionVerified = client.isSessionVerified
        hasCheckedVerificationState = client.hasCheckedVerificationState
    }

    /// Key backup and account recovery status.
    func encryptionStatus() async -> EncryptionStatus {
        guard let client else { return EncryptionStatus() }
        return await client.encryptionStatus()
    }

    /// Verified/unverified counts for this account's other sessions.
    /// Nil when logged out or the key query fails.
    func otherDeviceVerificationCounts() async -> (verified: Int, unverified: Int)? {
        guard let client, let userId = client.userId, let ownDevice = client.deviceId else {
            return nil
        }
        guard let queried = try? await client.keys.queryKeys(users: [userId]),
            let devices = queried.deviceKeys[userId.value]
        else {
            return nil
        }
        var verified = 0
        var unverified = 0
        for (deviceId, device) in devices where deviceId != ownDevice.value {
            if await client.crossSigning.isDeviceVerified(device) {
                verified += 1
            } else {
                unverified += 1
            }
        }
        return (verified, unverified)
    }

    /// Account capabilities advertised by the server. Nil when logged out
    /// or the fetch fails.
    func serverCapabilities() async -> ServerCapabilities? {
        guard let client else { return nil }
        return try? await client.auth.capabilities()
    }

    /// Decline the pending incoming verification request.
    func declinePendingVerificationRequest() async {
        guard let request = pendingVerificationRequest else { return }
        await declineVerificationRequest(request)
    }

    /// Decline an incoming verification request.
    func declineVerificationRequest(_ request: IncomingVerification) async {
        if pendingVerificationRequest == request {
            pendingVerificationRequest = nil
        }
        guard let client else { return }
        try? await client.verifications.declineRequest(
            MatrixKit.IncomingVerificationRequest(
                transactionId: request.flowId,
                sender: UserId(unchecked: request.senderId),
                deviceId: request.deviceId))
    }

    /// The shared verification monitor, for driving SAS flows.
    func verificationMonitor() async -> VerificationMonitor? {
        client?.verifications
    }

    /// Start verifying a peer device (requester role).
    func requestVerification(userId: String, deviceId: String?) async throws -> VerificationSession {
        guard let client else { throw RelayError.notLoggedIn }
        return try await client.verifications.requestVerification(
            userId: UserId(unchecked: userId), deviceId: deviceId)
    }

    /// Accept the pending incoming verification request (responder role).
    /// Stores the live session for the sheet and presents it. On failure
    /// the request stays pending so the user can retry or decline.
    func acceptPendingVerificationRequest() async {
        guard let request = pendingVerificationRequest else { return }
        do {
            activeVerificationSession = try await acceptVerificationRequest(request)
            shouldPresentVerificationSheet = true
        } catch {
            relayClientLogger.error(
                "Verification accept failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Accept an incoming verification request (responder role).
    func acceptVerificationRequest(
        _ request: IncomingVerification
    ) async throws -> VerificationSession {
        guard let client else { throw RelayError.notLoggedIn }
        let session = try await client.verifications.acceptRequest(
            MatrixKit.IncomingVerificationRequest(
                transactionId: request.flowId,
                sender: UserId(unchecked: request.senderId),
                deviceId: request.deviceId))
        pendingVerificationRequest = nil
        return session
    }

    /// MAC our keys after the user approves an SAS match: this device's
    /// ed25519 key plus the cross-signing master key when available. The
    /// monitor drives the rest of the flow (done) itself.
    func confirmVerification(_ session: VerificationSession) async throws {
        guard let client else { throw RelayError.notLoggedIn }
        try await client.verifications.confirm(session)
    }

    /// Post-SAS trust step for a completed self-verification (mirrors mx
    /// `postVerify`). With local cross-signing keys, sign the peer
    /// device; otherwise request the private halves from it — approving
    /// on the peer delivers them via `m.secret.send`, which heals
    /// verification state on arrival. Returns nil when the peer is not
    /// our own device (no trust step applies).
    func completeSelfVerification(
        _ session: VerificationSession
    ) async throws -> SelfVerifyCompletion? {
        guard let client else { throw RelayError.notLoggedIn }
        guard let userId = client.userId, await session.peerUserId == userId else {
            return nil
        }
        if await client.crossSigning.hasKeys {
            guard let peerDevice = await session.peerDeviceId else { return .verified }
            try await client.crossSigning.signDevice(
                userId: userId, deviceId: DeviceId(peerDevice))
            relayClientLogger.info(
                "Signed peer device \(userId, privacy: .public):\(peerDevice, privacy: .public)")
            return .verified
        }
        let peerDevice = await session.peerDeviceId
        _ = try await client.secrets.requestSecrets(
            from: userId, deviceId: peerDevice)
        relayClientLogger.info(
            "Requested cross-signing secrets: approve key sharing on \(peerDevice ?? "your other device", privacy: .public)")
        return .waitingForKeyShare
    }

    /// Recover 4S secrets with an `Es...` recovery key: unlocks secret
    /// storage and imports the cross-signing private keys. Returns the
    /// outcome, whose backup key feeds the separate `restoreKeyBackup`
    /// step.
    func recover(
        withRecoveryKey key: String,
        progress: (@Sendable (KeyFetchProgress) async -> Void)? = nil
    ) async throws -> RecoveryOutcome {
        guard let client else { throw RelayError.notLoggedIn }
        return try await client.recover(withRecoveryKey: key, progress: progress)
    }

    /// Recover 4S secrets with the account passphrase. CPU-heavy by
    /// design (PBKDF2 key derivation); prefer a detached task.
    func recover(
        withPassphrase passphrase: String,
        progress: (@Sendable (KeyFetchProgress) async -> Void)? = nil
    ) async throws -> RecoveryOutcome {
        guard let client else { throw RelayError.notLoggedIn }
        return try await client.recover(withPassphrase: passphrase, progress: progress)
    }

    /// Download and import every backed-up megolm session. Separate
    /// from recovery — restores are large and belong behind their own
    /// progress UI. Returns the number of sessions imported.
    func restoreKeyBackup(
        privateKey: Data,
        progress: (@Sendable (KeyFetchProgress) async -> Void)? = nil
    ) async throws -> Int {
        guard let client else { throw RelayError.notLoggedIn }
        return try await client.restoreKeyBackup(privateKey: privateKey, progress: progress)
    }

    /// Fires when incoming secret halves finish the set.
    func secretShareEvents() async -> AsyncStream<SecretShareEvent>? {
        guard let client else { return nil }
        return await client.secrets.events()
    }

    /// Ask a verified peer device for the key-backup private key
    /// (post-verification restore offer). The answer arrives through
    /// `secretShareEvents()` as `SecretShareEvent.backupKeyReceived`.
    /// Pass nil to ask all devices. Only peers holding the key answer.
    @discardableResult
    func requestBackupKey(from deviceId: String?) async throws -> String {
        guard let client, let userId = client.userId else {
            throw RelayError.notLoggedIn
        }
        return try await client.requestBackupKey(
            from: userId, deviceId: deviceId)
    }

    /// Ask every peer device for the key-backup key and restore it in
    /// the background via ``keyFetch``. Used by Settings; the
    /// verification sheet hands keys it already holds to the
    /// coordinator directly.
    func startBackupRestoreFromPeers() {
        guard !keyFetch.isRestoring else { return }
        Task {
            guard await encryptionStatus().backupEnabled else {
                errorReporter.report(.keyBackupRestoreFailed(
                    "Key backup is not enabled for this account."))
                return
            }
            guard (try? await requestBackupKey(from: nil)) != nil else {
                errorReporter.report(.keyBackupRestoreFailed(
                    "No device answered the backup key request."))
                return
            }
            guard let stream = await secretShareEvents() else { return }
            let key = await withTaskGroup(of: Data?.self) { group in
                group.addTask {
                    for await event in stream {
                        if case .backupKeyReceived(let key) = event {
                            return key
                        }
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(15))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let key else {
                errorReporter.report(.keyBackupRestoreFailed(
                    "No device answered the backup key request."))
                return
            }
            keyFetch.startBackupRestore(
                title: "Restoring message history", backupKey: key)
        }
    }

    /// Build a verification sheet model for an outgoing flow.
    func makeSessionVerificationViewModel() -> SessionVerificationViewModel {
        SessionVerificationViewModel(client: self)
    }

    // MARK: - Devices

    /// All known sessions, current device first by sort order upstream.
    func devices() async throws -> [DeviceInfo] {
        guard let client else { return [] }
        return try await client.auth.devices()
    }

    /// This session's device ID.
    func deviceId() async -> String? {
        await client?.session.deviceId.value
    }

    // MARK: - Account

    /// The homeserver URL this session is connected to.
    func homeserver() -> URL? {
        client?.homeserver
    }

    /// The local server name (`host[:port]`) for `via` fields on space
    /// membership events.
    private var localServerName: String? {
        guard let url = homeserver(), let host = url.host(), !host.isEmpty else {
            return nil
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    /// The current user's display name, if set.
    func userDisplayName() async -> String? {
        guard let client, let userId = client.userId else { return nil }
        return try? await client.profile.getDisplayName(userId)
    }

    /// The current user's avatar MXC URL, if set.
    func userAvatarURL() async -> String? {
        guard let client, let userId = client.userId else { return nil }
        return try? await client.profile.getAvatarURL(userId)?.value
    }

    /// Set the current user's display name.
    func setDisplayName(_ name: String) async throws {
        guard let client, let userId = client.userId else { return }
        try await client.profile.setDisplayName(userId, name: name)
    }

    /// Upload an avatar image and set it as the current user's avatar.
    /// Returns the MXC URL.
    @discardableResult
    func uploadUserAvatar(mimeType: String, data: Data) async throws -> String {
        guard let client, let userId = client.userId else {
            throw RelayError.notLoggedIn
        }
        let mxc = try await client.media.upload(data, mimeType: mimeType)
        try await client.profile.setAvatarURL(userId, url: mxc)
        return mxc.value
    }

    /// Clear the current user's avatar.
    func removeUserAvatar() async throws {
        guard let client, let userId = client.userId else { return }
        let _: EmptyResponse = try await client.transport.send(
            .put,
            path: "/_matrix/client/v3/profile/\(userId.value)/avatar_url",
            body: AvatarURLResponse(),
            accessToken: await client.session.accessToken)
    }

    // MARK: - Notifications

    /// Default notification mode for direct (or group) rooms.
    func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode {
        guard let client else { throw RelayError.notLoggedIn }
        return try await client.notifications.getDefaultNotificationMode(
            isOneToOne: isOneToOne)
    }

    /// Set the default notification mode for direct (or group) rooms.
    func setDefaultNotificationMode(isOneToOne: Bool, mode: DefaultNotificationMode) async throws {
        guard let client else { throw RelayError.notLoggedIn }
        try await client.notifications.setDefaultNotificationMode(
            isOneToOne: isOneToOne, mode: mode)
    }

    /// Notification keywords (also drive timeline highlights).
    func getNotificationKeywords() async throws -> [String] {
        guard let client else { return [] }
        return try await client.notifications.getNotificationKeywords()
    }

    /// Add a notification keyword.
    func addNotificationKeyword(_ keyword: String) async throws {
        guard let client else { return }
        try await client.notifications.addNotificationKeyword(keyword)
    }

    /// Remove a notification keyword.
    func removeNotificationKeyword(_ keyword: String) async throws {
        guard let client else { return }
        try await client.notifications.removeNotificationKeyword(keyword)
    }

    /// Whether call notifications are enabled.
    func isCallNotificationEnabled() async throws -> Bool {
        guard let client else { return false }
        return try await client.notifications.isCallNotificationEnabled()
    }

    /// Set whether call notifications are enabled.
    func setCallNotificationEnabled(_ enabled: Bool) async throws {
        guard let client else { return }
        try await client.notifications.setCallNotificationEnabled(enabled)
    }

    /// Whether invite notifications are enabled.
    func isInviteNotificationEnabled() async throws -> Bool {
        guard let client else { return true }
        return try await client.notifications.isInviteNotificationEnabled()
    }

    /// Set whether invite notifications are enabled.
    func setInviteNotificationEnabled(_ enabled: Bool) async throws {
        guard let client else { return }
        try await client.notifications.setInviteNotificationEnabled(enabled)
    }

    /// Whether whole-room mentions notify.
    func isRoomMentionEnabled() async throws -> Bool {
        guard let client else { return true }
        return try await client.notifications.isRoomMentionEnabled()
    }

    /// Set whether whole-room mentions notify.
    func setRoomMentionEnabled(_ enabled: Bool) async throws {
        guard let client else { return }
        try await client.notifications.setRoomMentionEnabled(enabled)
    }

    /// Whether direct user mentions notify.
    func isUserMentionEnabled() async throws -> Bool {
        guard let client else { return true }
        return try await client.notifications.isUserMentionEnabled()
    }

    /// Set whether direct user mentions notify.
    func setUserMentionEnabled(_ enabled: Bool) async throws {
        guard let client else { return }
        try await client.notifications.setUserMentionEnabled(enabled)
    }

    /// Whether encrypted/unencrypted notification settings are consistent.
    func hasConsistentNotificationSettings() async throws -> Bool {
        guard let client else { return true }
        return try await client.notifications.hasConsistentNotificationSettings()
    }

    /// Repair inconsistent encrypted/unencrypted notification settings.
    func fixInconsistentNotificationSettings() async throws {
        guard let client else { return }
        try await client.notifications.fixInconsistentNotificationSettings()
    }

    /// Room IDs with per-room notification overrides.
    func roomsWithCustomNotificationSettings() async throws -> [String] {
        guard let client else { return [] }
        return try await client.notifications.roomsWithCustomNotificationSettings().map(\.value)
    }

    /// Per-room notification mode override, if any.
    func roomNotificationMode(roomId: String) async throws -> RoomNotificationMode? {
        guard let client else { return nil }
        return try await client.notifications.getRoomNotificationMode(
            roomId: RoomId(unchecked: roomId))
    }

    /// Set a per-room notification mode override.
    func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws {
        guard let client else { return }
        try await client.notifications.setRoomNotificationMode(
            roomId: RoomId(unchecked: roomId), mode: mode)
        notificationModeCache[roomId] = mode
    }

    /// Clear a per-room notification mode override.
    func restoreDefaultRoomNotificationMode(roomId: String) async throws {
        guard let client else { return }
        try await client.notifications.restoreDefaultRoomNotificationMode(
            roomId: RoomId(unchecked: roomId))
        notificationModeCache.removeValue(forKey: roomId)
        if let room = rooms.first(where: { $0.roomId.value == roomId }) {
            notificationModeCache[roomId] = await effectiveDefault(for: room)
        }
    }

    // MARK: - Calls

    /// Joins the MatrixRTC call in `roomId` and returns a LiveKit-backed
    /// view model for it.
    ///
    /// Publishes our `m.call.member` state event and mints SFU credentials
    /// before returning; the caller drives `connect(url:token:sfuServiceURL:)`
    /// with the credentials from the join. Membership failures propagate to
    /// the caller — most commonly M_FORBIDDEN when the room's power levels
    /// don't let ordinary members send `m.call.member` (Relay-created rooms
    /// set the override at creation).
    func prepareCall(roomId: String) async throws -> CallViewModel {
        guard let client else { throw RelayError.notLoggedIn }
        let matrixRoomId = RoomId(unchecked: roomId)
        let room = await client.room(matrixRoomId)
        let session = RTCCallSession(client: client)
        let joined: JoinedCall
        do {
            joined = try await session.join(roomId: matrixRoomId)
        } catch {
            relayClientLogger.error(
                "Call join failed room=\(roomId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let userId = client.userId else { throw RelayError.notLoggedIn }
        let deviceId = await client.session.deviceId
        return CallViewModel(
            session: session,
            joined: joined,
            roomId: roomId,
            isRoomEncrypted: room.isEncrypted,
            localUserId: userId.value,
            localDeviceId: deviceId.value)
    }

    // MARK: - Room Administration

    /// Full room details (members, permissions, power levels).
    ///
    /// Falls back to the locally cached snapshot when the server fetch
    /// fails, so inspector UI never stalls on a spinner. The fallback
    /// omits permissions, power levels, and roles, which require full
    /// state. Failures are logged for diagnosis.
    func roomDetails(roomId: String) async -> RoomDetails? {
        guard let client else { return nil }
        let room = await client.room(RoomId(unchecked: roomId))
        do {
            var details = try await room.roomDetails()
            details.isDirect = RoomPresentation.presentsAsDirect(
                isDirect: details.isDirect,
                isSpace: room.isSpace,
                canonicalAlias: details.canonicalAlias,
                joinedMemberCount: details.memberCount)
            return details
        } catch {
            relayClientLogger.warning(
                "Full room details failed, using cached snapshot: \(error.localizedDescription, privacy: .public)")
            return cachedRoomDetails(room: room)
        }
    }

    /// Best-effort room details from locally cached state (no network).
    private func cachedRoomDetails(room: ObservableRoom) -> RoomDetails {
        RoomDetails(
            id: room.roomId,
            name: room.name,
            topic: room.topic,
            avatarURL: room.avatarURL,
            isEncrypted: room.isEncrypted,
            isPublic: false,
            isDirect: room.presentsAsDirect,
            canonicalAlias: room.canonicalAlias,
            alternativeAliases: room.altAliases,
            memberCount: room.memberDetails.count,
            members: room.memberDetails.map { userId, content in
                RoomMemberDetails(
                    userId: userId,
                    displayName: content.displayname,
                    avatarURL: content.avatarUrl.flatMap { try? MXCURI($0) })
            }.sorted { $0.resolvedName < $1.resolvedName },
            pinnedEventIds: room.pinnedEventIds,
            joinRule: nil,
            historyVisibility: nil,
            permissions: nil,
            powerLevelSettings: nil
        )
    }

    /// Change a member's power level.
    func setMemberPowerLevel(roomId: String, userId: String, powerLevel: Int) async throws {
        guard let client else { return }
        try await client.roomState.setMemberPowerLevel(
            RoomId(unchecked: roomId), userId: UserId(unchecked: userId),
            powerLevel: powerLevel)
    }

    /// Replace the room's power-level thresholds (read-modify-write).
    func updatePowerLevelSettings(roomId: String, settings: RoomPowerLevelSettings) async throws {
        guard let client else { return }
        try await client.roomState.updatePowerLevelSettings(
            RoomId(unchecked: roomId), settings: settings)
    }

    /// Kick a member.
    func kickMember(roomId: String, userId: String, reason: String? = nil) async throws {
        guard let client else { return }
        try await client.rooms.kick(
            RoomId(unchecked: roomId), user: UserId(unchecked: userId), reason: reason)
    }

    /// Ban a member.
    func banMember(roomId: String, userId: String, reason: String? = nil) async throws {
        guard let client else { return }
        try await client.rooms.ban(
            RoomId(unchecked: roomId), user: UserId(unchecked: userId), reason: reason)
    }

    /// Invite a user to a room.
    func inviteUser(roomId: String, userId: String) async throws {
        guard let client else { return }
        try await client.rooms.invite(
            RoomId(unchecked: roomId), user: UserId(unchecked: userId))
    }

    /// Rename a room.
    func setRoomName(roomId: String, name: String) async throws {
        guard let client else { return }
        try await client.room(RoomId(unchecked: roomId)).setName(name)
    }

    /// Retopic a room.
    func setRoomTopic(roomId: String, topic: String) async throws {
        guard let client else { return }
        try await client.room(RoomId(unchecked: roomId)).setTopic(topic)
    }

    /// Upload a room avatar.
    func uploadRoomAvatar(roomId: String, mimeType: String, data: Data) async throws {
        guard let client else { return }
        let mxc = try await client.media.upload(data, mimeType: mimeType)
        try await client.roomState.setAvatar(RoomId(unchecked: roomId), url: mxc)
    }

    /// Clear a room's avatar.
    func removeRoomAvatar(roomId: String) async throws {
        guard let client else { return }
        _ = try await client.roomState.sendStateEvent(
            RoomId(unchecked: roomId), type: "m.room.avatar", content: [:])
    }

    /// Change a room's join rule (`public`, `invite`, `knock`, ...).
    func updateJoinRule(roomId: String, rule: String) async throws {
        guard let client else { return }
        _ = try await client.roomState.sendStateEvent(
            RoomId(unchecked: roomId), type: "m.room.join_rules",
            content: ["join_rule": .string(rule)])
    }

    /// Change a room's history visibility.
    func updateHistoryVisibility(roomId: String, visibility: String) async throws {
        guard let client else { return }
        _ = try await client.roomState.sendStateEvent(
            RoomId(unchecked: roomId), type: "m.room.history_visibility",
            content: ["history_visibility": .string(visibility)])
    }

    /// Publish or hide a room in the public directory.
    func updateRoomVisibility(roomId: String, isPublic: Bool) async throws {
        guard let client else { return }
        let visibility = isPublic ? "public" : "private"
        let _: EmptyResponse = try await client.transport.send(
            .put,
            path: "/_matrix/client/v3/directory/list/room/\(RoomId(unchecked: roomId).value)",
            body: AnyCodableDictionary(["visibility": .string(visibility)]),
            accessToken: await client.session.accessToken)
    }

    /// Set the canonical alias and alternative aliases.
    func updateCanonicalAlias(roomId: String, alias: String?, altAliases: [String]) async throws {
        guard let client else { return }
        var content: [String: AnyCodable] = [
            "alt_aliases": .array(altAliases.map { .string($0) })
        ]
        if let alias {
            content["alias"] = .string(alias)
        }
        _ = try await client.roomState.sendStateEvent(
            RoomId(unchecked: roomId), type: "m.room.canonical_alias",
            content: content)
    }

    /// Publish a room alias. Returns false when the alias is taken.
    @discardableResult
    func publishRoomAlias(roomId: String, alias: String) async throws -> Bool {
        guard let client else { return false }
        try await client.rooms.publishAlias(
            RoomAlias(unchecked: alias), roomId: RoomId(unchecked: roomId))
        return true
    }

    /// Delete a room alias.
    func removeRoomAlias(_ alias: String) async throws {
        guard let client else { return }
        try await client.rooms.removeAlias(RoomAlias(unchecked: alias))
    }

    /// Whether a room alias is available.
    func isRoomAliasAvailable(_ alias: String) async throws -> Bool {
        guard let client else { return false }
        return try await client.rooms.isAliasAvailable(RoomAlias(unchecked: alias))
    }

    // MARK: - Directory & Search

    /// The server name (`host[:port]`) of the connected homeserver, if logged in.
    func homeServerName() -> String? {
        localServerName
    }

    /// List public rooms, optionally filtered by search text.
    /// Pass a `server` to browse that server's directory through the
    /// logged-in homeserver (federation-backed third-party directory
    /// lookup, e.g. `matrixrooms.info`). Pass nil for the local directory.
    /// Returns the page plus the cursor for the next page, if any.
    func publicRooms(
        filter: String? = nil, limit: Int = 100, since: String? = nil,
        server: String? = nil
    ) async throws -> (rooms: [PublicRoomEntry], nextBatch: String?) {
        guard let client else { return ([], nil) }
        let response = try await client.rooms.publicRooms(
            limit: limit, since: since, server: server, filter: filter)
        return (response.chunk, response.nextBatch)
    }

    /// Join a room by ID or alias.
    func joinRoom(idOrAlias: String) async throws {
        guard let client else { return }
        if idOrAlias.hasPrefix("!") {
            try await client.rooms.join(RoomId(unchecked: idOrAlias))
        } else {
            _ = try await client.rooms.join(RoomAlias(unchecked: idOrAlias))
        }
    }

    /// Preview a room's metadata and recent messages without joining.
    func roomPreview(roomId: String) async -> RoomPreview? {
        guard let client else { return nil }
        return try? await client.rooms.preview(RoomId(unchecked: roomId))
    }

    /// Server-side message search.
    func searchMessages(
        term: String, filter: MessageSearchFilter? = nil, from: String? = nil
    ) async throws -> (results: [MessageSearchResult], nextBatch: String?) {
        guard let client else { return ([], nil) }
        let (results, nextBatch, _) = try await client.search.search(
            term: term, filter: filter, from: from)
        return (results, nextBatch)
    }

    // MARK: - Rooms & Spaces

    /// Create a room or space.
    func createRoom(
        name: String, topic: String? = nil, address: String? = nil,
        isPublic: Bool = false, isEncrypted: Bool = true, isSpace: Bool = false,
        parentSpaceId: String? = nil, isDirect: Bool = false
    ) async throws -> String {
        guard let client else { throw RelayError.notLoggedIn }
        var request = CreateRoomRequest(
            visibility: isPublic ? .public : .private,
            name: name, topic: topic)
        if isDirect {
            request.isDirect = true
        }
        if let address, isPublic {
            request.roomAliasName = address
        }
        if isSpace {
            request.creationContent = ["type": .string("m.space")]
            if parentSpaceId != nil, let via = localServerName {
                request.initialState = [
                    InitialStateEvent(
                        type: "m.space.parent",
                        content: [
                            "canonical": .bool(true),
                            "via": .array([.string(via)]),
                        ])
                ]
            }
        } else if isEncrypted {
            request.initialState = [
                InitialStateEvent(
                    type: "m.room.encryption",
                    content: ["algorithm": .string("m.megolm.v1.aes-sha2")])
            ]
        }
        if !isSpace {
            // Let ordinary members publish `m.call.member` state so anyone
            // can join a call. Without this the event defaults to
            // `state_default` (50) and joins fail with M_FORBIDDEN.
            request.powerLevelContentOverride = [
                "events": .object(["org.matrix.msc3401.call.member": .int(0)])
            ]
        }
        let room = try await client.createRoom(request)
        // Spec creator behavior: record the room in our own `m.direct`.
        // Best effort (creation is not idempotent, so a bookkeeping
        // failure must not fail the call).
        if isDirect, let userId = client.userId {
            do {
                try await client.accountData.setDirectRoom(
                    room.roomId, for: userId, isDirect: true)
            } catch {
                relayClientLogger.warning(
                    "m.direct record failed for \(room.roomId.value, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return room.roomId.value
    }

    /// Open or create a direct-message room with a user.
    ///
    /// Returns the ID of an existing joined DM whose members are exactly
    /// this user and the local user. Otherwise creates a new private,
    /// encrypted DM room, invites the user, and records the room in our
    /// own `m.direct` (best effort, like ``createRoom(isDirect:)``).
    func createDirectMessage(userId: String) async throws -> String {
        guard let client else { throw RelayError.notLoggedIn }
        let peerId = UserId(unchecked: userId)
        if let selfId = client.userId {
            let expected: Set<UserId> = [selfId, peerId]
            if let existing = rooms.first(where: { room in
                guard room.membership == .join, room.presentsAsDirect else { return false }
                let joined = Set(room.memberDetails.filter { $0.value.membership == .join }.keys)
                return joined == expected
            }) {
                return existing.roomId.value
            }
        }
        var request = CreateRoomRequest(
            visibility: .private,
            invite: [peerId],
            preset: .trustedPrivateChat,
            isDirect: true)
        request.initialState = [
            InitialStateEvent(
                type: "m.room.encryption",
                content: ["algorithm": .string("m.megolm.v1.aes-sha2")])
        ]
        // Let ordinary members publish `m.call.member` state so anyone
        // can join a call (mirrors ``createRoom``).
        request.powerLevelContentOverride = [
            "events": .object(["org.matrix.msc3401.call.member": .int(0)])
        ]
        let room = try await client.createRoom(request)
        if let selfId = client.userId {
            do {
                try await client.accountData.setDirectRoom(
                    room.roomId, for: selfId, isDirect: true)
            } catch {
                relayClientLogger.warning(
                    "m.direct record failed for \(room.roomId.value, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return room.roomId.value
    }

    /// Add a room to a space.
    ///
    /// The child edge carries the local server as `via` so other users can
    /// route joins into the child.
    func addChildToSpace(childId: String, spaceId: String) async throws {
        guard let client else { return }
        try await client.spaces.addChild(
            RoomId(unchecked: childId),
            to: RoomId(unchecked: spaceId),
            via: localServerName.map { [$0] } ?? [])
    }

    /// Remove a room from a space.
    func removeChildFromSpace(childId: String, spaceId: String) async throws {
        guard let client else { return }
        try await client.spaces.removeChild(
            RoomId(unchecked: childId), from: RoomId(unchecked: spaceId))
    }

    /// A space's children hierarchy page plus the current level's
    /// direct child IDs and edges, and the next-page cursor, if any.
    ///
    /// The edges carry each direct child's `order` hint and timestamp for
    /// spec-compliant ordering of the current level.
    ///
    /// Fetched pages are cached on the space's store actor (and from there
    /// to the on-disk snapshot), so the next open renders from
    /// ``cachedSpaceHierarchy(spaceId:)`` without a network round trip.
    func spaceHierarchy(
        spaceId: String, since: String? = nil
    ) async throws -> (
        children: [SpaceChild],
        directChildIds: Set<String>,
        directChildren: [SpaceChildEdge],
        nextBatch: String?
    ) {
        guard let client else { return ([], [], [], nil) }
        let (children, direct, edges, next) = try await client.spaces.hierarchy(
            RoomId(unchecked: spaceId),
            from: since.map(BatchToken.init(_:)),
            limit: 100)
        return (
            children,
            Set(direct.map(\.value)),
            edges,
            next?.value)
    }

    /// Last-fetched hierarchy rows for a space from the local store (no
    /// network), plus the level's direct-child edges and the next-page
    /// cursor, if any. Empty when the space was never opened (or the cache
    /// was rebuilt since).
    func cachedSpaceHierarchy(spaceId: String) async -> (
        children: [SpaceChild],
        directChildren: [SpaceChildEdge],
        nextBatch: String?
    ) {
        guard let client else { return ([], [], nil) }
        guard
            let space = await client.store.existingRoom(
                RoomId(unchecked: spaceId))
        else { return ([], [], nil) }
        return (
            await space.hierarchyChildren,
            await space.hierarchyDirectChildren,
            await space.hierarchyNextBatch?.value)
    }

    /// Spaces the user can add children to.
    func editableSpaces() async throws -> [EditableSpace] {
        guard let client else { return [] }
        return try await client.spaces.editableSpaces()
    }

    /// Joined children listed while leaving a space.
    func leaveCandidates(spaceId: String) async throws -> [LeaveSpaceChild] {
        guard let client else { return [] }
        return try await client.spaces.leaveCandidates(spaceId: RoomId(unchecked: spaceId))
    }

    /// Leave a space and optionally its joined children.
    func leaveSpace(spaceId: String, leaveChildren: [String] = []) async throws -> [LeaveSpaceChild] {
        var leftovers: [LeaveSpaceChild] = []
        do {
            leftovers = try await leaveCandidates(spaceId: spaceId)
        } catch {
            // Best effort: still leave the space itself.
        }
        for childId in leaveChildren {
            try? await client?.rooms.leave(RoomId(unchecked: childId))
        }
        try await client?.rooms.leave(RoomId(unchecked: spaceId))
        return leftovers
    }

    /// Pinned messages as display-ready events.
    func pinnedMessages(roomId: String) async -> [ObservableTimelineEvent] {
        guard let client else { return [] }
        let room = await client.room(RoomId(unchecked: roomId))
        guard let events = try? await room.pinnedMessages() else { return [] }
        return events.map {
            ObservableTimelineEvent.make(
                from: $0, localUser: client.userId,
                members: room.memberDetails)
        }
    }

    /// Whether a user is on the ignore list.
    func isUserIgnored(userId: String) async -> Bool {
        guard let client else { return false }
        return (try? await client.accountData.ignoredUsers().contains(
            UserId(unchecked: userId))) ?? false
    }

    /// Ignore a user.
    func ignoreUser(userId: String) async throws {
        guard let client else { return }
        try await client.accountData.setIgnored(UserId(unchecked: userId), ignored: true)
    }

    /// Unignore a user.
    func unignoreUser(userId: String) async throws {
        guard let client else { return }
        try await client.accountData.setIgnored(UserId(unchecked: userId), ignored: false)
    }

    /// Refresh the share extension's room cache (best effort, background).
    func refreshShareRoomCache() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            var shareable: [ShareableRoom] = []
            for room in await self.rooms {
                guard await room.membership == .join, await room.isSpace == false else { continue }
                let avatarData: Data?
                if let mxc = await room.presentingAvatarURL?.value {
                    avatarData = await self.shareCacheAvatarData(mxcURL: mxc, size: 72)
                } else {
                    avatarData = nil
                }
                shareable.append(ShareableRoom(
                    id: await room.roomId.value,
                    name: await room.displayName,
                    isDirect: await room.presentsAsDirect,
                    avatarData: avatarData,
                    lastActivityTimestamp: await room.latestMessage?.timestamp))
            }
            PendingShareStore.writeRoomCache(shareable)
        }
    }

    /// Refresh the share extension's room cache on a slow poll.
    /// MatrixKit reassigns `roomList.joined` on every sync
    /// (set-semantics notification), so an observation-driven watcher
    /// is unusable here: a `withObservationTracking` loop wakes tens
    /// of thousands of times per second, pinning the main thread and
    /// leaking one tracking registration per wake (12GB in 10 minutes
    /// in Instruments). A 60s poll is plenty fresh for a share picker
    /// and allocates nothing between fires. Session teardown cancels
    /// via `stopTasks()`.
    private func startShareRoomCacheWatcher() {
        guard client != nil, shareCacheWatchTask == nil else { return }
        shareCacheWatchTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self.scheduleShareRoomCacheRefresh()
            }
        }
    }

    /// Schedule a share-cache refresh after a short debounce, so sync
    /// bursts don't hammer the app-group container.
    private func scheduleShareRoomCacheRefresh() {
        shareCacheDebounceTask?.cancel()
        shareCacheDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.refreshShareRoomCache()
        }
    }

    /// Donate an outgoing-message intent so the system share sheet
    /// suggests this conversation. Best effort; failures are silent.
    func donateOutgoingInteraction(roomId: String) {
        guard let room = rooms.first(where: { $0.roomId.value == roomId }) else { return }
        intentDonation.donateOutgoingMessage(roomId: roomId, roomName: room.displayName)
    }

    // MARK: - Private

    private func adopt(client: MatrixClient, userId: String) async {
        self.client = client
        authState = .loggedIn(userId: userId)
        remoteSignOutNoticed = false
        resetActivityState()
        let isOIDC = await client.session.isOIDC
        let hasRefreshToken = await client.session.refreshToken != nil
        relayClientLogger.debug(
            "Session adopted oidc=\(isOIDC, privacy: .public) hasRefreshToken=\(hasRefreshToken, privacy: .public)")
        startNetworkMonitor()
        // Publish device keys + one-time keys so peers can resolve this
        // device (verification requests otherwise go unanswered), then
        // route to-device crypto traffic and restore room keys. Bootstrap
        // failures are non-fatal: plaintext sync still works.
        do {
            try await RelayClient.bootstrapEncryption(
                on: client, keystore: keychain)
            await client.secrets.autoload()
            relayClientLogger.debug("Device keys published")
            recordActivity("Device keys published")
        } catch {
            relayClientLogger.warning(
                "Encryption bootstrap failed: \(error.localizedDescription, privacy: .public)")
            recordActivity("Encryption bootstrap failed")
        }
        await client.configureEncryption()
        relayClientLogger.debug("Restoring cached snapshot")
        await restoreCache(into: client)
        relayClientLogger.debug("Cache restore done")
        syncState = .syncing
        do {
            relayClientLogger.debug("Starting initial sync")
            try await initialSyncRoundTrip()
            relayClientLogger.debug("Initial sync request done")
            // Heal rooms whose avatar update sync missed (e.g. delivered
            // only inside a timeline window): one cheap state-event fetch
            // each. DMs are skipped since they present a member avatar.
            // Runs before `saveCache()` so healed avatars persist.
            for room in client.roomList.joined
                where room.avatarURL == nil && !room.presentsAsDirect
            {
                if await room.hydrateMissingAvatar() {
                    relayClientLogger.info(
                        "Healed missing room avatar room=\(room.roomId.value, privacy: .public)")
                }
            }
            saveCache()
            await persistSessionLoudly(for: client, context: "initial sync")
            hasLoadedRooms = true
            syncState = .running
            relayClientLogger.info("Initial sync completed")
            recordActivity("Initial sync completed")
            startVerificationMonitor()
            startSecretsMonitor()
            startNotificationMonitor()
            await refreshVerificationState()
        } catch is CancellationError {
            // The caller went away mid-sync (e.g. a torn-down view task),
            // not a sync failure: leave state alone, the live loop starting
            // below takes over.
            relayClientLogger.debug("Initial sync cancelled by caller")
            recordActivity("Initial sync cancelled")
        } catch {
            relayClientLogger.error(
                "Initial sync failed: \(error.localizedDescription, privacy: .public)")
            if Self.isSessionInvalidation(error) {
                await confirmSessionInvalidation(
                    source: "initial sync", softLogout: Self.softLogoutHint(error))
            } else {
                syncState = .error(error.localizedDescription)
                syncStats.recordError(error.localizedDescription)
                recordActivity("Initial sync failed")
            }
        }
        // The live loop starts regardless: a failed initial sync (e.g. a
        // cancelled login-transition task) must not leave the client
        // without sync forever. `startSyncLoop` is idempotent. Notification
        // modes hydrate here rather than in the success branch above so a
        // cancelled or failed initial sync cannot leave the cache empty
        // for the session (which would drop mute markers and mute-based
        // badge suppression). Refreshes are safe to repeat: entries are
        // keyed by room ID.
        await refreshNotificationModes()
        refreshShareRoomCache()
        startSessionServices()
    }

    private func startSyncLoop() {
        guard let client, syncTask == nil else { return }
        syncStopRequested = false
        // The Labs sliding-sync experiment replaces the classic loop.
        // Unknown versions proceed optimistically; known-unsupported
        // servers fall back to classic sync (the toggle is disabled there).
        let useSliding = isSlidingSyncEnabled && client.canUseSlidingSync
        usingSlidingSync = useSliding
        syncTask = Task {
            do {
                if useSliding {
                    try await client.startSlidingSync()
                } else {
                    try await client.startSync()
                }
            } catch {
                if Self.isSessionInvalidation(error) {
                    // Verify on a fresh task: this task's epilogue clears
                    // `syncTask`, so resuming inline would orphan the
                    // replacement loop's handle.
                    let hint = Self.softLogoutHint(error)
                    Task {
                        await self.confirmSessionInvalidation(
                            source: "sync loop", softLogout: hint)
                    }
                } else {
                    relayClientLogger.error(
                        "Sync loop stopped: \(error.localizedDescription, privacy: .public)")
                    if syncState == .running {
                        syncState = .error(error.localizedDescription)
                        syncStats.recordError(error.localizedDescription)
                        recordActivity("Sync loop stopped")
                    }
                }
            }
            syncTask = nil
        }
        startSyncWatchLoop()
    }

    /// Watchdog for silent sync-loop death. MatrixKit ends a revoked-token
    /// loop by finishing its delta stream (sync status back to `.idle`)
    /// rather than throwing, so `startSyncLoop` never sees it. When the
    /// loop dies unexpectedly with the network up, verify with `whoami`:
    /// a rejected token means remote sign-out, anything else restarts
    /// the loop and lets the SDK's own retry/backoff take over.
    private func startSyncWatchLoop() {
        guard syncWatchTask == nil else { return }
        syncWatchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await checkSyncLiveness()
            }
        }
    }

    private func checkSyncLiveness() async {
        guard !syncStopRequested, !remoteSignOutNoticed,
            isNetworkConnected, didFinishStartupSync,
            let client, case .loggedIn = authState,
            syncState == .running
        else { return }
        let status = usingSlidingSync ? client.slidingSyncStatus : client.syncStatus
        guard case .idle = status else { return }
        await verifySessionAfterSyncDeath()
    }

    /// One-shot `whoami` probe: only a rejected token proves remote
    /// sign-out. Anything else restarts the loop.
    private func verifySessionAfterSyncDeath() async {
        guard let client, !remoteSignOutNoticed else { return }
        do {
            _ = try await client.auth.whoAmI()
            relayClientLogger.warning("Sync loop ended with a live token; restarting")
            recordActivity("Sync loop restarted")
            syncStopRequested = false
            startSyncLoop()
        } catch {
            if Self.isSessionInvalidation(error) {
                handleRemoteSignOut(
                    softLogout: Self.softLogoutHint(error), source: "liveness probe")
            } else {
                relayClientLogger.warning(
                    "Sync liveness probe failed, restarting loop: \(error.localizedDescription, privacy: .public)")
                syncStopRequested = false
                startSyncLoop()
            }
        }
    }

    /// Whether `error` is a dead or absent access token
    /// (`M_UNKNOWN_TOKEN`). MatrixKit surfaces this from any
    /// authenticated call: sync, token refresh, and one-shot fetches.
    static func isSessionInvalidation(_ error: Error) -> Bool {
        guard let matrixError = error as? MatrixError else { return false }
        if case .unknownToken = matrixError { return true }
        return false
    }

    /// The response's `soft_logout` hint carried by an unknown-token
    /// error (nil when absent or when `error` is not one).
    static func softLogoutHint(_ error: Error) -> Bool? {
        guard let matrixError = error as? MatrixError,
            case .unknownToken(let softLogout) = matrixError
        else { return nil }
        return softLogout
    }

    /// Confirm a suspected session invalidation before arming the
    /// sign-out alert. The transport already retried once past a
    /// refresh, but a rotation may still have been in flight, so one
    /// explicit `whoami` probe decides: a live token resumes the
    /// session (persisting any rotated tokens); only a second
    /// rejection arms the alert. Anything else leaves the session
    /// frozen with an error state instead of signing out.
    private func confirmSessionInvalidation(source: String, softLogout: Bool?) async {
        guard let client, !remoteSignOutNoticed else { return }
        do {
            _ = try await client.auth.whoAmI()
            relayClientLogger.warning(
                "Session probe succeeded after \(source, privacy: .public); resuming sync")
            recordActivity("Session probe succeeded; sync resumed")
            await persistSessionLoudly(for: client, context: "session probe")
            stopTasks()
            syncState = .running
            startSessionServices()
        } catch {
            if Self.isSessionInvalidation(error) {
                handleRemoteSignOut(
                    softLogout: Self.softLogoutHint(error), source: source)
            } else {
                relayClientLogger.error(
                    "Session probe failed (\(source, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                syncState = .error(error.localizedDescription)
                syncStats.recordError(error.localizedDescription)
                recordActivity("Session probe failed")
            }
        }
    }

    /// Retry the session after the sign-out alert is dismissed without
    /// signing out (Escape, window teardown, app quit). Never destroys
    /// anything: a live token resumes the session, a still-dead token
    /// keeps the alert armed, and anything else stands the alert down
    /// with an error state. Safe to call during termination.
    func retrySessionAfterRemoteSignOut() async {
        guard remoteSignOutNoticed, let client else { return }
        do {
            _ = try await client.auth.whoAmI()
            relayClientLogger.info("Session retry succeeded; resuming sync")
            recordActivity("Session retry succeeded; sync resumed")
            await persistSessionLoudly(for: client, context: "session retry")
            remoteSignOutNoticed = false
            stopTasks()
            syncState = .running
            startSessionServices()
        } catch {
            if Self.isSessionInvalidation(error) {
                relayClientLogger.error(
                    "Session retry failed: token still rejected; keeping sign-out alert armed")
            } else {
                relayClientLogger.error(
                    "Session retry inconclusive: \(error.localizedDescription, privacy: .public)")
                remoteSignOutNoticed = false
                syncState = .error(error.localizedDescription)
                syncStats.recordError(error.localizedDescription)
                recordActivity("Session retry inconclusive")
            }
        }
    }

    /// (Re)start the long-lived per-session services `stopTasks()`
    /// tears down. Idempotent: every starter guards on its task handle.
    private func startSessionServices() {
        startNetworkMonitor()
        startVerificationMonitor()
        startSecretsMonitor()
        startNotificationMonitor()
        startShareRoomCacheWatcher()
        didFinishStartupSync = true
        startSyncLoop()
        scheduleTokenRefresh()
    }

    /// Freeze the session after the homeserver rejects our token: stop
    /// all loops and raise the blocking sign-out alert. Idempotent:
    /// sync, refresh, and one-shot failures converge here. The alert
    /// itself is non-destructive — only its explicit Sign Out button
    /// wipes the session (see `retrySessionAfterRemoteSignOut`).
    func handleRemoteSignOut(softLogout: Bool? = nil, source: String = "unspecified") {
        guard !remoteSignOutNoticed else { return }
        remoteSignOutNoticed = true
        syncState = .idle
        stopTasks()
        syncStats.recordError("Session signed out remotely")
        recordActivity("Session signed out remotely")
        relayClientLogger.error(
            "Access token rejected (source: \(source, privacy: .public), soft logout: \(softLogout.map(String.init(describing:)) ?? "unknown", privacy: .public)): session signed out remotely"
        )
    }

    /// Restart the sync loop when the Labs sliding-sync preference
    /// changes mid-session. No-ops before startup completes or while
    /// offline (reconnect restarts via `startSyncIfNeeded`, which
    /// re-reads the preference), and when the running loop already
    /// matches the preference.
    private func applySyncModePreference() {
        guard let client, didFinishStartupSync, isNetworkConnected else { return }
        let wantSliding = isSlidingSyncEnabled && client.canUseSlidingSync
        guard wantSliding != usingSlidingSync else { return }
        syncStopRequested = true
        syncTask?.cancel()
        syncTask = nil
        relayClientLogger.info(
            "\(wantSliding ? "Switching to sliding sync" : "Switching to classic sync", privacy: .public)")
        Task {
            await client.stopSync()
            await client.stopSlidingSync()
            startSyncLoop()
        }
    }

    /// Proactively rotate tokens at two-thirds of their advertised
    /// lifetime and persist the rotation, so expiry never surfaces as a
    /// sync failure. Unknown lifetimes (restored sessions) recheck every
    /// minute. Transport-level retry covers races in between.
    private func scheduleTokenRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(await tokenRefreshDelay()))
                guard !Task.isCancelled else { return }
                await refreshSessionTokens()
            }
        }
    }

    private func tokenRefreshDelay() async -> Double {
        guard
            let client,
            let ms = await client.session.expiresInMs, ms > 0
        else {
            return 60
        }
        return max(60, Double(ms) / 1000 * 2 / 3)
    }

    private func refreshSessionTokens() async {
        guard let client else { return }
        do {
            try await client.auth.refresh()
            await persistSessionLoudly(for: client, context: "token refresh")
            relayClientLogger.debug("Session tokens refreshed")
        } catch {
            relayClientLogger.warning(
                "Session token refresh failed: \(error.localizedDescription, privacy: .public)")
            recordActivity("Session token refresh failed")
            if Self.isSessionInvalidation(error) {
                // The refresh token is dead; the access token may still
                // be alive, so probe before raising the sign-out alert.
                await verifySessionAfterSyncDeath()
            }
        }
    }

    private func startVerificationMonitor() {
        guard let client, verificationTask == nil else { return }
        verificationTask = Task {
            let stream = await client.verifications.events()
            for await event in stream {
                switch event {
                case .requestReceived(let request):
                    relayClientLogger.info(
                        "Verification request received from \(request.sender.value, privacy: .public) device \(request.deviceId, privacy: .public)")
                    recordActivity("Verification request received")
                    pendingVerificationRequest = IncomingVerification(
                        flowId: request.transactionId,
                        deviceId: request.deviceId,
                        senderId: request.sender.value)
                case .sessionFinished:
                    recordActivity("Verification completed")
                    await refreshVerificationState()
                case .sasReady:
                    break
                case .failed(let transactionId, let message):
                    relayClientLogger.error(
                        "Verification failed \(transactionId, privacy: .public): \(message, privacy: .public)")
                    recordActivity("Verification failed")
                }
            }
        }
    }

    /// Watch for cross-signing secret completion (the peer approved key
    /// sharing after a secret-less self-verification) and heal the
    /// copied verification state so the banner clears live.
    private func startSecretsMonitor() {
        guard let client, secretsTask == nil else { return }
        secretsTask = Task {
            let stream = await client.secrets.events()
            for await _ in stream {
                relayClientLogger.info(
                    "Cross-signing secrets received: refreshing verification state")
                recordActivity("Cross-signing secrets received")
                await refreshVerificationState()
            }
        }
    }

    /// Subscribe to room-message notifications. Ends on cancellation.
    func notificationEvents() -> AsyncStream<RoomMessageNotification> {
        let (stream, continuation) = AsyncStream<RoomMessageNotification>.makeStream()
        notificationContinuations.append(continuation)
        return stream
    }

    private func notifyMessage(_ notification: RoomMessageNotification) {
        for continuation in notificationContinuations {
            continuation.yield(notification)
        }
    }

    /// Watch live sync deltas and fan out per-message notifications.
    ///
    /// The monitor subscribes before the live loop starts, and startup
    /// history arrives via `syncOnce` (which never emits deltas), so only
    /// new messages notify. Own messages, redactions, edits, and events
    /// at or below the per-room notified watermark are skipped.
    private func startNotificationMonitor() {
        guard let client, notificationTask == nil else { return }
        notificationTask = Task {
            let stream = client.deltas()
            for await delta in stream {
                await handleSyncDelta(delta)
            }
        }
    }

    private func handleSyncDelta(_ delta: SyncDelta) async {
        syncStats.record(delta: delta)
        guard let client, let myId = client.userId else { return }
        logMembershipTransitions(delta)
        for (roomId, joined) in delta.joined where !joined.timeline.isEmpty {
            guard let room = rooms.first(where: { $0.roomId == roomId }) else { continue }
            for event in joined.timeline {
                if event.type == "m.room.encrypted" { continue }
                guard event.type == EventType.roomMessage.rawValue,
                      !event.isRedacted,
                      event.sender != myId,
                      let content = event.messageContent,
                      !content.body.isEmpty,
                      content.relatesTo?.relType != .replacement,
                      event.originServerTs > lastNotifiedEventTimestamp[roomId.value, default: 0]
                else { continue }
                lastNotifiedEventTimestamp[roomId.value] = event.originServerTs
                let mode = await effectiveNotificationMode(for: room)
                guard mode != .mute else { continue }
                let mention = isMention(
                    body: content.body, mentions: content.mentions, myId: myId)
                if mode == .mentionsAndKeywordsOnly, !mention { continue }
                notifyMessage(RoomMessageNotification(
                    eventId: event.eventId.value,
                    roomId: roomId.value,
                    roomName: room.displayName,
                    authorName: room.memberDetails[event.sender]?.displayname,
                    body: content.body,
                    isMention: mention,
                    isDirect: room.isDirect))
            }
        }
    }

    /// Log own-membership transitions (invites, leaves) to the room-list
    /// category. Deltas only flow from live sync — startup history arrives
    /// via `syncOnce`, which never emits them — so this never replays.
    private func logMembershipTransitions(_ delta: SyncDelta) {
        for roomId in delta.joined.keys { loggedInviteRoomIds.remove(roomId.value) }
        for (roomId, invite) in delta.invited {
            guard loggedInviteRoomIds.insert(roomId.value).inserted else { continue }
            let invitedName = roomDisplayName(for: roomId)
            relayClientLogger.info(
                "Invited to \(invitedName, privacy: .public) from \(invite.inviter?.value ?? "?", privacy: .public) room=\(roomId.value, privacy: .public)")
            recordActivity("Invited to \(invitedName)")
        }
        for roomId in delta.left.keys {
            guard loggedLeftRoomIds.insert(roomId.value).inserted else { continue }
            let leftName = roomDisplayName(for: roomId)
            relayClientLogger.info(
                "Left \(leftName, privacy: .public) room=\(roomId.value, privacy: .public)")
            recordActivity("Left \(leftName)")
        }
    }

    private func roomDisplayName(for roomId: RoomId) -> String {
        rooms.first(where: { $0.roomId == roomId })?.displayName ?? roomId.value
    }

    /// Whether a message body mentions the local user: an explicit
    /// `m.mentions` entry (user or `@room`), the body naming the user ID,
    /// or a highlight-keyword match.
    private func isMention(body: String, mentions: Mentions?, myId: UserId) -> Bool {
        if let mentions {
            if mentions.room == true { return true }
            if let userIds = mentions.userIds, userIds.contains(myId) { return true }
        }
        if body.localizedStandardContains(myId.value) { return true }
        for keyword in notificationKeywords where !keyword.isEmpty {
            if body.localizedStandardContains(keyword) { return true }
        }
        return false
    }

    private func stopTasks() {
        syncStopRequested = true
        syncTask?.cancel()
        syncTask = nil
        syncWatchTask?.cancel()
        syncWatchTask = nil
        verificationTask?.cancel()
        verificationTask = nil
        secretsTask?.cancel()
        secretsTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        shareCacheWatchTask?.cancel()
        shareCacheWatchTask = nil
        shareCacheDebounceTask?.cancel()
        shareCacheDebounceTask = nil
        keyFetch.stopAll()
        monitor?.cancel()
        monitor = nil
    }

    // MARK: - Activity

    /// Reset per-session activity state (fresh login or restore).
    private func resetActivityState() {
        syncStats = SyncStats()
        recentActivity = []
        sessionStartedAt = Date()
    }

    /// Append a notable moment to the Activity window feed (capped at 20).
    private func recordActivity(_ text: String) {
        recentActivity.append(ActivityEntry(text: text))
        if recentActivity.count > 20 {
            recentActivity.removeFirst(recentActivity.count - 20)
        }
    }

    /// Compare `"v1.13"`-style spec versions numerically.
    private static func compareSpecVersion(_ left: String, _ right: String) -> ComparisonResult {
        func parts(_ string: String) -> [Int] {
            var text = string
            if text.hasPrefix("v") || text.hasPrefix("r") { text.removeFirst() }
            return text.split(separator: ".").compactMap { Int($0) }
        }
        let leftParts = parts(left), rightParts = parts(right)
        for (x, y) in zip(leftParts, rightParts) where x != y {
            return x < y ? .orderedAscending : .orderedDescending
        }
        if leftParts.count == rightParts.count { return .orderedSame }
        return leftParts.count < rightParts.count ? .orderedAscending : .orderedDescending
    }

    private func startNetworkMonitor() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let connected = path.status == .satisfied
                self.isNetworkConnected = connected
                if !connected {
                    relayClientLogger.warning("Connectivity lost")
                    self.recordActivity("Connectivity lost")
                    if self.syncState == .running || self.syncState == .syncing {
                        self.syncState = .offline
                    }
                    self.syncTask?.cancel()
                    self.syncTask = nil
                } else {
                    if self.syncState == .offline {
                        relayClientLogger.info("Connectivity restored")
                        self.recordActivity("Connectivity restored")
                        self.syncState = .running
                    }
                    self.startSyncIfNeeded()
                }
            }
        }
        monitor.start(queue: .global(qos: .background))
    }

    private func homeserverURL(_ homeserver: String) throws -> URL {
        let trimmed = homeserver.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixed = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: prefixed) else {
            throw RelayError.oauthInvalidURL
        }
        return url
    }

    /// Persist the session, logging loudly on failure. A rotation that
    /// succeeds server-side but never reaches the keychain strands the
    /// next launch with a consumed refresh token, so these failures
    /// must never be silent.
    private func persistSessionLoudly(for client: MatrixClient, context: String) async {
        do {
            try await persistSession(for: client)
        } catch {
            relayClientLogger.error(
                "Session persist failed (\(context, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            recordActivity("Session persist failed (\(context))")
        }
    }

    private func persistSession(for client: MatrixClient) async throws {
        guard
            let userId = client.userId?.value,
            let deviceId = client.deviceId?.value,
            let accessToken = await client.session.accessToken.nilIfEmpty
        else {
            throw RelayError.notLoggedIn
        }
        let stored = StoredSession(
            homeserver: client.homeserver.absoluteString,
            userId: userId,
            deviceId: deviceId,
            accessToken: accessToken,
            refreshToken: await client.session.refreshToken,
            oidcClientId: await client.session.oidcClientId,
            oidcTokenEndpoint: await client.session.oidcTokenEndpoint)
        let data = try JSONEncoder().encode(stored)
        try await keychain.save(
            data,
            for: KeyStoreKey(
                service: Self.sessionService, account: Self.sessionAccount))
    }

    private func cache(for userId: UserId) -> SwiftDataCache? {
        guard let file = SwiftDataCache.databaseURL(for: userId) else { return nil }
        return try? SwiftDataCache(database: file)
    }

    private func restoreCache(into client: MatrixClient) async {
        guard
            let userId = client.userId,
            let snapshot = await cache(for: userId)?.load()
        else {
            return
        }
        await client.store.restore(snapshot)
        await client.roomList.refresh()
        for room in snapshot.rooms {
            if let mode = room.notificationMode {
                notificationModeCache[room.roomId.value] = mode
            }
        }
        hasLoadedRooms = true
    }

    /// Settle any debounced crypto-state writes immediately.
    /// Best-effort durability for paths where the debounce loss
    /// window is unacceptable (e.g. app termination). No-op when
    /// logged out.
    func flushCryptoState() async {
        guard let client else { return }
        await client.olm.flushCryptoState()
        await client.roomCrypto.flushCryptoState()
    }

    /// Best-effort persist of converged in-memory state (read markers
    /// especially): without it the on-disk snapshot is forever the
    /// pre-convergence startup state and every launch replays the flash.
    private func saveCacheThrottled() {
        guard Date() >= earliestNextBackgroundSave else { return }
        earliestNextBackgroundSave = Date().addingTimeInterval(60)
        saveCache()
    }

    private func saveCache() {
        guard let client, let userId = client.userId else { return }
        Task {
            var snapshot = await client.store.snapshot()
            for index in snapshot.rooms.indices {
                if let mode = notificationModeCache[snapshot.rooms[index].roomId.value] {
                    snapshot.rooms[index].notificationMode = mode
                }
            }
            Task.detached(priority: .background) {
                guard let file = SwiftDataCache.databaseURL(for: userId) else { return }
                try? await SwiftDataCache(database: file).save(snapshot)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
