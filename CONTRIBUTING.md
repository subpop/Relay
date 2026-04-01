# Contributing to Relay

Thanks for your interest in contributing to Relay! This document covers how to
get started, how to submit changes, and where to find help.

## Get Involved

Join us in the Matrix room to ask questions, discuss ideas, or just say hello:

[#relayapp:matrix.org](https://matrix.to/#/#relayapp:matrix.org)

## Building from Source

Relay is a native macOS app built with SwiftUI and Xcode.

### Requirements

- macOS 26.0 (Tahoe) or later
- Xcode 26.0 or later

### Steps

1. Clone the repository:

   ```
   git clone https://github.com/subpop/Relay.git
   cd Relay
   ```

2. Open `Relay.xcodeproj` in Xcode.
3. Xcode will automatically resolve Swift Package dependencies (`matrix-rust-components-swift`, `swift-async-algorithms`).
4. Select the **Relay** scheme and build (`Cmd+B`) or run (`Cmd+R`).

## Project Structure

| Directory | Description |
|---|---|
| `Relay/` | App target -- SwiftUI views, view models, and app entry point |
| `RelaySDK/` | Framework target -- Matrix Rust SDK integration, services, and business logic |
| `Packages/RelayCore/` | Local Swift package -- shared protocols and model types |
| `RelayTests/` | Unit tests |
| `RelayUITests/` | UI tests |

## Submitting Changes

1. Fork the repository and create a branch from `main`.
2. Make your changes. Try to keep commits focused and atomic.
3. Use imperative mood, sentence-case commit messages (e.g. "Add thread support
   to timeline view").
4. Open a pull request against `main` with a clear description of what your
   change does and why.

## Reporting Issues

Open an issue on the [GitHub issue tracker](https://github.com/subpop/Relay/issues).
Include steps to reproduce the problem, what you expected to happen, and what
actually happened. Screenshots or logs are always helpful.

## License

By contributing to Relay, you agree that your contributions will be licensed
under the [Apache License 2.0](LICENSE).
