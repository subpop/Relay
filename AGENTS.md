# Karpathy Guidelines

Behavioral guidelines to reduce common LLM coding mistakes, derived from [Andrej Karpathy's observations](https://x.com/karpathy/status/2015883857489522876) on LLM coding pitfalls.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

# Project Specific Instructions

## Project Overview

Relay is a native macOS Matrix client built with SwiftUI, backed by
[MatrixKit](https://github.com/subpop/MatrixKit) — a pure-Swift SDK, providing
the `MatrixKit`, `MatrixKitCrypto`, `MatrixKitSwiftData`, and `MatrixRTC`
products.

- **Relay/** -- App target (SwiftUI views, view models, `RelayClient`
  facade, app-side services and utilities)
- **MatrixKit** -- SDK layer (protocol, transport, sync, crypto,
  persistence). Developed as Relay's protocol layer; agents may propose
  MatrixKit changes to maintain the Matrix/protocol vs. Relay/app
  boundary.
- **Packages/RelayShared/** -- Local SPM package (app-group bridge:
  `AppGroup`, `PendingShare`, `PendingShareStore`, `ShareableRoom`;
  zero dependencies, `Codable`-only)
- **RelayShareExtension/** -- Share extension target (room picker +
  file handoff; imports `RelayShared` only, no MatrixKit, no network)
- **RelayTests/** -- Unit test target

Views import `MatrixKit` directly and observe the concrete
`RelayClient` via `@Environment(RelayClient.self)`. `RelayApp.swift`
creates the `RelayClient` once and injects it with
`.environment(client)`.

## Build & Test

- Open `Relay.xcodeproj` in Xcode 26+.
- Build: `Cmd+B` with the **Relay** scheme selected.
- Run tests: `Cmd+U` or use `xcodebuild test`.
- Requires macOS 26.0 (Tahoe) or later.

## Code Conventions

- **Swift 6** with strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`). Respect `Sendable` and actor-isolation rules.
- Prefer `Task @MainActor` over `DispatchQueue.main.async` for main
  queue execution.
- Use `@Observable` and `@Environment` for state management.
- Bridge SDK callbacks to Swift concurrency with `AsyncStream`.
- Keep commits focused and atomic. Use imperative mood, sentence-case
  commit messages (e.g. "Add thread support to timeline view").
- Comments should reflect the current state of the code. Documentation
  should not discuss previous iterations of the code, only the current one.
- Follow standard, idiomatic, Apple-recommended guidelines as much as possible.

## Commit Conventions

- Include a summary of what changed in the commit message.
- When authoring a commit, use either `Assisted-By: <name of code assistant>` or
  `Generated-By: <name of code assistant"` in the commit message
  footer.
  - **Assisted-By**: You directed the work and edited meaningfully
    (default for typical use).
  - **Generated-By**:  A substantial portion was generated with
    minimal human edit (e.g. full file scaffold).
- Never push commits without explicit approval from the user.

## Architecture Rules

- Respect the Matrix/app boundary: protocol, transport, sync, crypto,
  and persistence logic belongs in `MatrixKit`; app UX, view state,
  and composition belongs in `Relay/`. Propose MatrixKit changes when
  a Relay fix requires an SDK capability, rather than working around
  the SDK app-side.
- `RelayClient` (`Relay/Services/RelayClient.swift`) is the single
  app facade (session restore/login/OIDC, sync lifecycle, keychain
  session, SwiftData cache, verification, notifications, media).
  Route cross-cutting session/sync/room logic through it. Per-room
  timeline state lives in `TimelineViewModel` (`Relay/ViewModels/`),
  a thin layer over MatrixKit's `ObservableRoom`.
- Views and view models use MatrixKit concrete types directly
  (`ObservableRoom`, `ObservableTimelineEvent`, `RoomId`, …) — there
  is no protocol-interposition layer.
- Keep `Packages/RelayShared/` zero-dependency and `Codable`-only.
  It is imported by both the app and the share extension.
- `RelayShareExtension/` imports `RelayShared` only. It never touches
  MatrixKit or the network; it writes files + a `PendingShare` record
  to the app group, and the main app sends them.
- Previews construct a bare `RelayClient()` (or fixture view models)
  directly. `RelayApp.swift` skips heavy services under
  `XCODE_RUNNING_FOR_PREVIEWS`.

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

## Swift Instructions

- `@Observable` classes must be marked `@MainActor` unless the project has Main Actor default actor isolation. Flag any `@Observable` class missing this annotation.
- All shared data should use `@Observable` classes with `@State` (for ownership) and `@Bindable` / `@Environment` (for passing).
- Strongly prefer not to use `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, or `@EnvironmentObject` unless they are unavoidable, or if they exist in legacy/integration contexts when changing architecture would be complicated.
- Assume strict Swift concurrency rules are being applied.
- Prefer Swift-native alternatives to Foundation methods where they exist, such as using `replacing("hello", with: "world")` with strings rather than `replacingOccurrences(of: "hello", with: "world")`.
- Prefer modern Foundation API, for example `URL.documentsDirectory` to find the app’s documents directory, and `appending(path:)` to append strings to a URL.
- Never use C-style number formatting such as `Text(String(format: "%.2f", abs(myNumber)))`; always use `Text(abs(change), format: .number.precision(.fractionLength(2)))` instead.
- Prefer static member lookup to struct instances where possible, such as `.circle` rather than `Circle()`, and `.borderedProminent` rather than `BorderedProminentButtonStyle()`.
- Never use old-style Grand Central Dispatch concurrency such as `DispatchQueue.main.async()`. If behavior like this is needed, always use modern Swift concurrency.
- Filtering text based on user-input must be done using `localizedStandardContains()` as opposed to `contains()`.
- Avoid force unwraps and force `try` unless it is unrecoverable.
- Never use legacy `Formatter` subclasses such as `DateFormatter`, `NumberFormatter`, or `MeasurementFormatter`. Always use the modern `FormatStyle` API instead. For example, to format a date, use `myDate.formatted(date: .abbreviated, time: .shortened)`. To parse a date from a string, use `Date(inputString, strategy: .iso8601)`. For numbers, use `myNumber.formatted(.number)` or custom format styles.

## SwiftUI Instructions

- Always use `foregroundStyle()` instead of `foregroundColor()`.
- Always use `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`.
- Always use the `Tab` API instead of `tabItem()`.
- Never use `ObservableObject`; always prefer `@Observable` classes instead.
- Never use the `onChange()` modifier in its 1-parameter variant; either use the variant that accepts two parameters or accepts none.
- Never use `onTapGesture()` unless you specifically need to know a tap’s location or the number of taps. All other usages should use `Button`.
- Never use `Task.sleep(nanoseconds:)`; always use `Task.sleep(for:)` instead.
- Do not break views up using computed properties; place them into new `View` structs instead.
- Do not force specific font sizes; prefer using Dynamic Type instead.
- Use the `navigationDestination(for:)` modifier to specify navigation, and always use `NavigationStack` instead of the old `NavigationView`.
- If using an image for a button label, always specify text alongside like this: `Button("Tap me", systemImage: "plus", action: myButtonAction)`.
- Don’t apply the `fontWeight()` modifier unless there is good reason. If you want to make some text bold, always use `bold()` instead of `fontWeight(.bold)`.
- Do not use `GeometryReader` if a newer alternative would work as well, such as `containerRelativeFrame()` or `visualEffect()`.
- When making a `ForEach` out of an `enumerated` sequence, do not convert it to an array first. So, prefer `ForEach(x.enumerated(), id: \.element.id)` instead of `ForEach(Array(x.enumerated()), id: \.element.id)`.
- When hiding scroll view indicators, use the `.scrollIndicators(.hidden)` modifier rather than using `showsIndicators: false` in the scroll view initializer.
- Use the newest ScrollView APIs for item scrolling and positioning (e.g. `ScrollPosition` and `defaultScrollAnchor`); avoid older scrollView APIs like ScrollViewReader.
- Place view logic into view models or similar, so it can be tested.
- Avoid `AnyView` unless it is absolutely required.
- Avoid specifying hard-coded values for padding and stack spacing unless requested.
