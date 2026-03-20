Relay (working title) is a Matrix client that doesn't look like a Matrix client.

A native macOS chat app built with SwiftUI that wraps the [Matrix Rust SDK](https://github.com/matrix-org/matrix-rust-sdk) via UniFFI-generated Swift bindings. Relay aims to feel like a first-class Mac app — fast, lightweight, and keyboard-friendly — while speaking the Matrix protocol under the hood.

## Feature Overview

- **Room list & navigation** — browse joined rooms with unread counts and room avatars.
- **Rich timeline** — text, emote, notice, image, video, audio, and file messages with proper grouping, date headers, and sender avatars.
- **Reactions** — toggle emoji reactions on any message via context menu or emoji picker.
- **Reply rendering** — inline reply previews with click-to-jump-to-original.
- **Unread markers** — a "New" divider appears at the first unread message.
- **Image attachments** — send images (with blurhash placeholders) and other files via drag-and-drop or the attach button, all sandbox-safe.
- **Room directory search** — discover and join public rooms.
- **Infinite scrollback** — paginate backwards through history with a single click.
- **Auto-scroll** — the timeline stays pinned to the bottom for new messages, but won't interrupt you if you've scrolled up.
- **Keychain-backed sessions** — login credentials are stored securely in the macOS Keychain.

## Roadmap

### In Progress

- [ ] Room creation
- [ ] Direct/private messaging
- [ ] Message scrollback sync

### Planned

- [ ] Thread support
- [ ] Notification sync

## Known Issues

- [ ] Sometimes a room doesn't mark messages as read, even when the room is focused.
- [ ] Sometimes a room clears its message list and doesn't render it until the view is resized.
- [ ] Sometimes a room refreshes its message list upon receiving a new one, removing the message history until the room view is refreshed.

# License

Apache 2.0. See the [LICENSE](./LICENSE) file for details.

---

Made with ❤️. Fueled by ☕️ and 🤖.
