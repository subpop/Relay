# Architecture

Relay is a native macOS Matrix client built with SwiftUI, backed by
[MatrixKit](https://github.com/subpop/MatrixKit) — a pure-Swift SDK,
providing the `MatrixKit`, `MatrixKitCrypto`, `MatrixKitSwiftData`,
and `MatrixRTC` products.

## Dependency Graph

```
MatrixKit
  MatrixKit ───────────── pure-Swift protocol/transport/sync layer
  MatrixKitCrypto ──────── keystore / crypto primitives
  MatrixKitSwiftData ───── snapshot cache (depends on MatrixKit)
  MatrixRTC ────────────── LiveKit-backed calls
        ▲                 ▲
        │                 │
Relay.app ────────────────┼── imports MatrixKit (+Crypto/SwiftData/RTC in RelayClient)
  RelayClient (@Observable facade, @Environment-injected)
  Views / ViewModels / Models → MatrixKit concrete types directly
  RelayShared (local Packages/RelayShared, zero dependencies)
        ▲
RelayShareExtension ──────┘ (imports RelayShared ONLY; file-based handoff,
                             no MatrixKit, no network; the main app sends)
```

There is no `RelayKit` framework target, no `RelayInterface` package,
and no Rust SDK in the build.

### MatrixKit

The SDK layer. Protocol, transport, sync, crypto, and persistence
live here, not in Relay. MatrixKit exposes actor-based clients and
`@Observable @MainActor` models (`ObservableRoom`,
`ObservableTimelineEvent`, `RoomId`, …) with `AsyncStream` updates.

MatrixKit is developed as Relay's protocol layer: agents may propose
MatrixKit changes to maintain the Matrix/protocol vs. Relay/app
boundary, rather than working around a missing SDK capability
app-side.

### Relay.app

The application target (`Relay/`). Views import `MatrixKit` directly
and observe the concrete `RelayClient` — there is no
protocol-interposition layer.

- **`RelayClient`** (`Relay/Services/RelayClient.swift`) — the single
  app facade. Owns the `MatrixClient` lifecycle (session restore,
  password login, OIDC, sync start/stop, logout), persists sessions
  via `KeychainKeyStore`, caches snapshots in SwiftData, tracks
  connectivity (`NWPathMonitor`), and coordinates verification
  (SAS/4S/key backup), notification modes, and media/avatar fetching.
  Created once in `RelayApp.swift` and injected with
  `.environment(client)`; views read it via
  `@Environment(RelayClient.self)`.
- **`TimelineViewModel`** (`Relay/ViewModels/`) — per-room state over
  MatrixKit's `ObservableRoom` (`events:
  [ObservableTimelineEvent]`, pagination, read markers, send/edit/
  react/redact). Cheap to create; callers make one per opened room.
- **App-side services** — `ActivityLog` (diagnostic ring buffer fed
  by `RelayClient`), `GiphyService` (+ `GIFSearchServiceProtocol`),
  `IntentDonationService`, `ComposeDraftStore`, `ErrorReporter`.
- **Views/Models/Utilities** — SwiftUI views, `MatrixHTMLParser`,
  mention/emoji helpers, text scaling, inspector/settings/directory/
  search/space view models.

### Packages/RelayShared

The app ⇄ share-extension bridge. A local SPM package with **zero
dependencies** — `Codable`-only types both targets import:

- `AppGroup` — group identifier + `containerURL` helper.
- `PendingShare` — handoff record (`id`, `roomId`, `filenames`,
  `timestamp`).
- `PendingShareStore` — app-group manifest + `pending-shares/`
  file dir + `shareable-rooms*.json` room cache.
- `ShareableRoom` — serializable room snapshot (`id`, `name`,
  `isDirect`, `avatarData?`, `lastActivityTimestamp?`).

### RelayShareExtension

A deferred-send bridge that never touches Matrix. It imports
`RelayShared` only (plus `AppKit`/`SwiftUI`/
`UniformTypeIdentifiers`):

1. `ShareExtensionRoomProvider` reads the `shareable-rooms.json`
   cache the main app wrote, sorted by recent activity.
2. `ShareView` shows the room picker + attachment preview.
3. `ShareViewController` copies each `NSItemProvider` payload into
   the app-group `pending-shares/` dir, appends a `PendingShare`
   record, writes `latest-share-id.txt`, and activates the main app.
4. `RelayApp.checkForPendingShare()` (on `didBecomeActive`) loads
   the record, navigates to the room, and stages the files in the
   compose bar for user review. The main app sends.

## Key Design Patterns

### Facade + Environment Injection

```
RelayClient                    (concrete @Observable, in Relay/)
    └── MatrixKit.MatrixClient (SDK lifecycle, sync, rooms, crypto)
```

`RelayApp` owns one `RelayClient` (`@State`) and injects it into
`ContentView`, `SettingsView`, and `ActivityLogView`. Views declare
`@Environment(RelayClient.self) private var client` and call it
directly. Previews construct a bare `RelayClient()` (or fixture
view models); `RelayApp` skips heavy services under
`XCODE_RUNNING_FOR_PREVIEWS`.

### Thin Per-Room View Models

Cross-cutting session/sync/room logic lives in `RelayClient`.
Per-room timeline state lives in `TimelineViewModel`, a thin layer
that projects `ObservableRoom`/`ObservableTimelineEvent` into
view-ready state (filtering, grouping inputs, loading flags).

### File-Based Extension Handoff

The extension and the app never share memory or SDK state — only
files in the app group plus `Codable` records in `RelayShared`.
This keeps the extension entitlement surface small and crash-safe:
a failed copy just leaves an unsent file, never a half-sent event.

## Concurrency Model

- Swift 6 strict concurrency with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- View models and `RelayClient` are `@MainActor`-isolated
  `@Observable` classes.
- MatrixKit I/O runs on its own actors; updates reach the UI as
  `AsyncStream` values consumed in `Task` blocks on the main actor.

## File Overview

```
Relay/
  RelayApp.swift              App entry point (creates RelayClient, share pickup, notifications)
  ContentView.swift           Routes on RelayClient.AuthState / SyncState
  Views/                      SwiftUI views (import MatrixKit directly)
  ViewModels/                 TimelineViewModel, SearchViewModel, RoomDirectoryViewModel,
                              SpaceHierarchyViewModel, SessionVerificationViewModel, fixtures
  Services/                   RelayClient, KeychainKeyStore, ActivityLog,
                              GiphyService, IntentDonationService
  Models/ Utilities/          RoomDetails, MatrixHTMLParser, EmojiDetection, …
  Generated/Secrets.swift     GIPHY key plumbing (see Secrets.xcconfig)

Packages/RelayShared/
  Sources/RelayShared/
    AppGroup.swift            Group identifier + containerURL
    PendingShare.swift        Handoff record
    PendingShareStore.swift   Manifest + file dir + room cache
    ShareableRoom.swift       Serializable room snapshot

RelayShareExtension/
  ShareViewController.swift   Entry point; file copy + handoff write
  ShareView.swift             Room picker UI
  ShareExtensionRoomProvider.swift  Reads cached rooms (no SDK)

RelayTests/                   Unit tests (parsers, captions, read markers, …)

MatrixKit   SDK: MatrixKit, MatrixKitCrypto, MatrixKitSwiftData, MatrixRTC
```

## History

Relay previously wrapped the Matrix Rust SDK via a `RelayKit`
framework and a `RelayInterface` protocol package. That stack
(including the Rust binary, `MatrixService`, and
`PreviewMatrixService`) was deleted during the MatrixKit migration.
If you see those names in old comments, they refer to the
pre-migration design.
