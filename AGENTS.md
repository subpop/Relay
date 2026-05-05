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
