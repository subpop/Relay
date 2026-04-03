# Agents

Guidelines for AI coding agents working in this repository.

## Project Overview

Relay is a native macOS Matrix client built with SwiftUI. The codebase is
organized into three layers:

- **Relay/** -- App target (SwiftUI views, entry point)
- **RelayKit/** -- Framework target (Matrix Rust SDK integration, services,
  view models)
- **Packages/RelayInterface/** -- Local SPM package (shared protocols and
  model types, zero dependencies)

Views program against `RelayInterface` protocols, not concrete SDK types.
Only `RelayApp.swift` imports `RelayKit` directly.

## Build & Test

- Open `Relay.xcodeproj` in Xcode 26+.
- Build: `Cmd+B` with the **Relay** scheme selected.
- Run tests: `Cmd+U` or use `xcodebuild test`.
- Requires macOS 26.0 (Tahoe) or later.

## Code Conventions

- **Swift 6** with strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`). Respect `Sendable` and actor-isolation rules.
- Use `@Observable` and `@Environment` for state management.
- Bridge SDK callbacks to Swift concurrency with `AsyncStream`.
- Keep commits focused and atomic. Use imperative mood, sentence-case
  commit messages (e.g. "Add thread support to timeline view").

## Architecture Rules

- Never import `MatrixRustSDK` or `RelayKit` from view code. Views depend
  only on `RelayInterface` protocols.
- New SDK wrappers go in `RelayKit/`. New protocols and shared models go
  in `Packages/RelayInterface/`.
- Previews must work without loading the Rust binary. Use mock
  implementations that conform to `RelayInterface` protocols.

## UI Design

Always verify UI changes against the latest **Apple Human Interface
Guidelines**: https://developer.apple.com/design/human-interface-guidelines/

Relay should look and feel like a first-class macOS app, not a cross-platform
or web-based client. When in doubt, reference native Apple apps (Messages,
Mail) for interaction patterns, spacing, and typography. Key points:

- Use standard macOS controls and layout conventions.
- Respect system settings (appearance, accent color, accessibility).
- Prefer SF Symbols for iconography.
- Follow platform conventions for navigation, toolbars, and sidebars.
