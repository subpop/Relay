# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Relay is a native macOS Matrix chat client built with SwiftUI. It wraps the Matrix Rust SDK (via UniFFI-generated Swift bindings) to provide a first-class Mac experience for the Matrix protocol.

**Requirements:** macOS 26.0+ (Tahoe), Xcode 26.0+

## Build & Run

Open `Relay.xcodeproj` in Xcode. Dependencies resolve automatically via SPM.

```bash
# Build
xcodebuild -scheme Relay -destination 'platform=macOS' build

# Run tests
xcodebuild -scheme Relay -destination 'platform=macOS' test
```

## Architecture

Three-layer separation:

- **Relay/** (App target) — SwiftUI views and preview view models. Entry point is `RelayApp.swift`, which injects `MatrixService` via SwiftUI environment. `ContentView` routes based on `AuthState` (logged out → login, logged in → main view). `MainView` is a two-pane layout: room list on the left, timeline on the right.

- **RelaySDK/** (Framework target) — All Matrix SDK integration and business logic. `MatrixService` is the central `@Observable @MainActor` coordinator that owns sub-services:
  - `AuthenticationService` — login (password + OAuth/OIDC), session restore
  - `SyncManager` — sync lifecycle
  - `RoomListManager` — reactive room list via SDK's `RoomListService`
  - `RoomDetailViewModel` — timeline state and message sending
  - `MediaService` — avatar/media caching
  - `TimelineMessageMapper` — converts Rust SDK events to `TimelineMessage` models
  - `KeychainService` — secure credential storage

- **Packages/RelayCore/** (Local Swift package) — Shared protocols (`MatrixServiceProtocol`, `RoomDetailViewModelProtocol`) and model types (`TimelineMessage`, `RoomSummary`, etc.). This enables the app target to use preview/mock implementations without importing RelaySDK.

## Key Dependencies (SPM)

- `matrix-rust-components-swift` — Matrix Rust SDK UniFFI bindings
- `swift-async-algorithms` — Async/await utilities
- `SwiftSoup` — HTML parsing for formatted messages
- `swift-collections` — Efficient data structures

## Conventions

- Commit messages: imperative mood, sentence-case (e.g. "Add thread support to timeline view")
- Views bind directly to `@Observable` state; no Combine publishers
- Protocol-driven design allows preview implementations in the app target without the real SDK
