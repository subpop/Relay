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