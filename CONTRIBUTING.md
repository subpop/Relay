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

2. Create your local secrets file from the template:

   ```
   cp Secrets.xcconfig.example Secrets.xcconfig
   ```

   Open `Secrets.xcconfig` and fill in your values:

   - **`DEVELOPMENT_TEAM`** -- Your Apple Developer Team ID. Find it in
     Xcode under **Settings > Accounts**, or at
     <https://developer.apple.com/account>.
   - **`GIPHY_API_KEY`** -- Required for GIF search functionality. Create
     one at <https://developers.giphy.com/dashboard/>.

   `Secrets.xcconfig` is gitignored and will not be committed.

3. Open `Relay.xcodeproj` in Xcode.
4. Xcode will automatically resolve Swift Package dependencies.
5. Select the **Relay** scheme and build (`Cmd+B`) or run (`Cmd+R`).

## Project Structure

| Directory | Description |
|---|---|
| `Relay/` | App target -- SwiftUI views, view models, `RelayClient` facade, app-side services |
| `MatrixKit` | SDK ([MatrixKit](https://github.com/subpop/MatrixKit)) -- products: `MatrixKit`, `MatrixKitCrypto`, `MatrixKitSwiftData`, `MatrixRTC` |
| `Packages/RelayShared/` | Local Swift package -- app-group bridge (`AppGroup`, `PendingShare`, `ShareableRoom`; zero dependencies) |
| `RelayShareExtension/` | Share extension target -- room picker + file handoff (`RelayShared` only) |
| `RelayTests/` | Unit test target |

## Local Homeserver for Screenshots

A seed script is included to spin up a local Matrix homeserver populated with
realistic data. This is useful for taking screenshots, testing UI with real
room/message data, or working on features without connecting to a live server.

### Requirements

- A container runtime ([Docker](https://www.docker.com/),
  [Podman](https://podman.io/), or
  [Apple Containers](https://developer.apple.com/documentation/apple-containers))
- `curl`
- `jq` (`brew install jq`)

### Running the Script

```
./scripts/seed-homeserver.sh
```

To use a different container runtime:

```
CONTAINER_RUNTIME=podman ./scripts/seed-homeserver.sh
```

The script starts a [continuwuity](https://github.com/continuwuity/continuwuity)
homeserver in a container and seeds it with users, spaces, rooms, and messages
for a fictional software company called "Pebble". It takes about 30 seconds to
complete.

### Signing In

After the script finishes, open Relay (Debug build) and sign in on the sign-in
page:

| Field | Value |
|---|---|
| Matrix ID | `@alex:pebble.dev` |
| Password | `pebble123` |
| Homeserver URL | `http://localhost:8008` |

The "Homeserver URL" field is only available in Debug builds.

### User Avatars

Place avatar images in `scripts/profiles/`, named by username (e.g.
`morgan.png`, `priya.jpg`). The script uploads any images it finds and skips
users without one.

### Managing the Server

```
# Stop the server
docker stop relay-homeserver

# Start it again
docker start relay-homeserver

# Delete everything and start fresh
docker rm -v relay-homeserver && docker volume rm relay-homeserver-data
```

Replace `docker` with your container runtime if different.

## Localizing Relay

Relay's UI strings live in String Catalogs.

| File | Contents |
|---|---|
| `Relay/Localizable.xcstrings` | App UI strings |
| `Relay/InfoPlist.xcstrings` | App metadata strings (e.g. permission prompts) |
| `RelayShareExtension/Localizable.xcstrings` | Share extension strings |

Source strings are written in English (`en`). Don't edit the English text
when translating; if a source string is unclear or wrong, open an issue or PR
for it separately.

### Translating with Xcode

1. Open `Relay.xcodeproj` and select the catalog you want to translate.
2. To add a new language, click **+** at the bottom of the catalog editor and
   choose it. This also adds the language to the project's known regions.
3. Translate each string. Use the **Needs Review** filter to find strings that
   are new or changed, and mark finished strings as translated.
4. Respect format specifiers (`%@`, `%lld`, …) and keep them intact, using
   positional specifiers (`%1$@`, `%2$@`) if the word order differs in your
   language. Use plural variations where your language requires them.
5. Build and run Relay with your language (**Product > Scheme > Edit Scheme >
   Run > Options > App Language**) to check that translations fit the UI.

### Translating with SimpleLocalize

`Relay/Localizable.xcstrings` is synced with
[SimpleLocalize](https://simplelocalize.io) (see `simplelocalize-github.yml`).
Source strings are uploaded when changes land on `main`, and translations are
returned as an "Update translations" pull request. Ask in the
[Matrix room](https://matrix.to/#/#relayapp:matrix.org) if you'd like to
translate there instead of editing the catalog directly.

### Submitting a translation

Open a pull request as described in [Submitting Changes](#submitting-changes).
Keep one language per pull request, and use a message such as "Add German
translations". If you're adding a new language, mention it in the description
so a maintainer can confirm it's complete enough to ship.

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
