# midnight-ssh iOS/iPadOS Implementation Plan

## Goal

Ship a native iPadOS and iOS version of `midnight-ssh` that reuses the existing Rust SSH/SFTP core and feels like a first-class Apple platform app.

The first mobile release should not try to be a full macOS clone. The iPad version should support real server work with terminal, SFTP, editing, and dashboards. The iPhone version should focus on incident response: connect quickly, inspect health, tail logs, run trusted snippets, and make small edits.

## Product Shape

### iPadOS

Primary target for v1.

- Multi-column layout with connections, workspace, and inspector/dashboard.
- Hardware keyboard first terminal.
- Split terminal + SFTP/editor workflows.
- Multiple SSH sessions, but with conservative resource limits.
- Server dashboard adapted from the macOS right panel.
- File editor for config, shell, YAML, SQL, and plain text files.
- Snippets and command palette for repeated operational tasks.

### iOS

Second target, sharing the same app binary if practical.

- One connection-focused navigation stack.
- Fast connect and reconnect.
- Terminal with touch-friendly accessory keys.
- Server health summary.
- Logs, UFW/systemd status, and snippets.
- SFTP file browser with editor for small text/config changes.
- Face ID protected vault.

### Not v1

- Long-running background SSH sessions. iOS will suspend the app; recommend tmux/mosh-style persistence instead.
- Full dashboard desktop mode on iPhone.
- Team sharing.
- Android UI. Keep the Rust core portable so Android can follow with Kotlin/Compose and UniFFI bindings.

## Architecture

### Keep the Current Winning Shape

Reuse:

- `r-shell-core` for SSH, SFTP, PTY, connection lifecycle, event bus, and host-key trust.
- `r-shell-macos` Rust bridge patterns for UniFFI and typed Swift APIs.
- SwiftUI app architecture from the macOS app where it is genuinely portable.

Do not port the React/Tauri UI to mobile. The iOS/iPadOS app should be native SwiftUI with a small amount of UIKit where needed for terminal/editor behavior.

### Recommended Repo Layout

Start with an incremental layout to avoid a large rename:

```text
r-shell-macos/
  RShellApp/                 # Existing macOS app
  RShellMobile/              # New iOS/iPadOS app target sources
  Sources/RShellMacOS/       # Existing pure Swift shared models, later renamed
  bindings/                  # Generated UniFFI Swift bindings
  project.yml                # Add iOS app targets here initially
```

After the iOS MVP is stable, consider a cleanup rename:

```text
r-shell-apple/
  Sources/RShellShared/
  Sources/RShellBridge/
  Apps/macOS/
  Apps/iOS/
```

Do the rename only after the mobile target builds and ships internally.

### Rust Bridge

The Swift-facing bridge must stay boring and well-typed.

- No raw JSON in Swift APIs except diagnostic export internals.
- Use UniFFI records and enums for connection profiles, file entries, monitor snapshots, UFW state, process rows, and PTY frames.
- Keep functions synchronous from Swift's perspective only where calls are short.
- For long operations, expose an operation id plus event callbacks, or use Swift async wrappers around blocking bridge calls.
- Keep all bridge DTOs platform-neutral; do not leak AppKit or UIKit concepts into Rust.

### Build Targets

Add Rust targets:

```bash
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim
rustup target add x86_64-apple-ios
```

Build universal iOS artifacts:

```bash
cargo build -p r-shell-macos --release --target aarch64-apple-ios
cargo build -p r-shell-macos --release --target aarch64-apple-ios-sim
cargo build -p r-shell-macos --release --target x86_64-apple-ios
```

Create XCFrameworks for the Rust static library and C headers/modulemap so Xcode can link both device and simulator builds cleanly.

## Milestones

## Milestone 0: Feasibility Spike

Target: 2-4 days.

Tasks:

- Build `r-shell-core` and `r-shell-macos` for iOS simulator and device targets.
- Identify non-portable crates, linker flags, and platform APIs.
- Generate UniFFI Swift bindings for iOS.
- Create a minimal iOS app target that calls `rshellInit`.
- Confirm Keychain APIs work on simulator and device.
- Confirm a simple TCP connection can be opened from an iOS device.

Acceptance criteria:

- `xcodebuild` can build an iOS simulator app.
- The app initializes the Rust bridge without crashing.
- A test screen can call a harmless bridge function and display the result.

Risks to resolve:

- Rust dependencies that assume macOS APIs.
- Static linking issues with `libresolv`, `Security`, `zlib`, or `libxml2`.
- UniFFI modulemap differences between macOS and iOS.

## Milestone 1: Shared Apple App Foundation

Target: 1 week.

Tasks:

- Add an iOS/iPadOS target in `r-shell-macos/project.yml`.
- Add `RShellMobile/` source directory.
- Extract portable Swift models from macOS app into shared source groups:
  - `ConnectionProfile`
  - `ConnectionKind`
  - `TerminalConnectionStatus`
  - Keychain account naming
  - Host-key display helpers
  - Theme definitions where portable
- Create `MobileBridgeManager` or make `BridgeManager` platform-neutral.
- Add platform capability wrappers:
  - `PlatformKeychain`
  - `PlatformClipboard`
  - `PlatformFilePicker`
  - `PlatformBiometricGate`
  - `PlatformLogger`

Acceptance criteria:

- macOS app still builds.
- iOS app builds.
- Shared models are compiled by both app targets.
- Platform-specific code is isolated behind `#if os(macOS)` and `#if os(iOS)` only at boundaries.

## Milestone 2: iPad Connection MVP

Target: 1-2 weeks.

Tasks:

- Implement iPad app shell with `NavigationSplitView`.
- Add connection list:
  - saved hosts
  - folders
  - search
  - add/edit/delete
  - local encrypted storage
- Implement connect/disconnect/reconnect.
- Store credentials in iOS Keychain.
- Add Face ID/Touch ID gate for opening the vault.
- Show connection status dots and connection detail view.
- Add onboarding for importing SSH keys through Files.

Acceptance criteria:

- User can create an SSH profile on iPad.
- User can connect using password auth.
- User can connect using private key auth.
- Credentials survive app restart.
- Failed auth produces a clear recoverable error.

## Milestone 3: Terminal on iPad

Target: 1-2 weeks.

Tasks:

- Integrate SwiftTerm on iOS/iPadOS.
- Wire PTY start/input/output/resize through the Rust bridge.
- Add terminal accessory bar for software keyboard:
  - Esc
  - Tab
  - Ctrl
  - Alt
  - arrows
  - slash
  - pipe
  - dash
  - function key layer
- Add hardware keyboard commands:
  - new tab
  - close tab
  - reconnect
  - search
  - copy/paste
  - command palette
- Handle scene lifecycle:
  - pause input on background
  - show reconnect state on resume
  - recommend tmux for persistent sessions
- Add terminal themes, font size, cursor style, and scrollback settings.

Acceptance criteria:

- Interactive SSH terminal works on iPad device.
- Hardware keyboard typing is reliable.
- Software keyboard accessory sends expected control keys.
- Terminal resizes correctly on rotation and split view.
- Background/resume does not leave a broken UI state.

## Milestone 4: iPad SFTP and Editor

Target: 1-2 weeks.

Tasks:

- Port the macOS file browser concept to SwiftUI for iPad.
- Support:
  - list directory
  - upload
  - download
  - rename
  - delete
  - new folder
  - row selection
  - double-tap open
- Add modal editor for:
  - `.yaml`
  - `.yml`
  - `.txt`
  - `.sh`
  - `.sql`
  - dot-prefixed config files
- Use a UIKit-backed text editor first for predictable selection and keyboard behavior.
- Add lightweight syntax highlighting for shell, YAML, and SQL.
- Use document picker for local import/export.

Acceptance criteria:

- User can browse remote files on iPad.
- User can edit and save a remote config file.
- User can upload and download files through the Files picker.
- Large binary files are not accidentally loaded into the text editor.

## Milestone 5: Server Dashboard and DevOps Panels

Target: 1-2 weeks.

Tasks:

- Port mobile-safe versions of:
  - system stats
  - processes
  - logs
  - systemd services
  - Docker
  - PostgreSQL
  - UFW
  - world map
- Make panels command-driven and resilient when a server lacks a tool.
- Use compact cards on iPhone and columns on iPad.
- Add refresh controls and last-updated timestamps.
- Add snippet actions from panels:
  - restart service
  - tail logs
  - open config
  - inspect firewall

Acceptance criteria:

- iPad can show terminal and dashboard side by side.
- iPhone can show a concise server health summary.
- Panels degrade cleanly when tools are missing.
- No panel runs destructive commands without confirmation.

## Milestone 6: iPhone Adaptation

Target: 1-2 weeks.

Tasks:

- Add iPhone-specific navigation with `NavigationStack`.
- Optimize terminal for one-handed and external-keyboard workflows.
- Replace wide dashboard layouts with stacked summaries.
- Add quick actions:
  - connect
  - reconnect
  - run snippet
  - tail log
  - open SFTP
  - open dashboard
- Add lock screen privacy behavior:
  - blur terminal when app moves inactive
  - require biometric unlock after timeout

Acceptance criteria:

- App is usable on iPhone without layout clipping.
- Common incident tasks take fewer than 3 taps after opening a saved host.
- Terminal and editor do not fight the software keyboard.

## Milestone 7: StoreKit, Licensing, and Beta

Target: 1 week.

Tasks:

- Add StoreKit 2.
- Implement feature gates:
  - free saved-host limit
  - Pro unlock
  - lifetime unlock
  - restore purchases
- Keep all core SSH functionality usable enough to evaluate the app.
- Add privacy nutrition labels.
- Add App Store review demo profile or mock mode.
- Create TestFlight internal group.
- Create public beta group after crash rate is stable.

Acceptance criteria:

- Purchases and restore work in sandbox.
- Paid entitlements sync across iPhone and iPad through App Store receipt.
- Free users can evaluate terminal quality without entering payment first.
- App Review can test without private infrastructure.

## Milestone 8: Launch Hardening

Target: 1 week.

Tasks:

- Add crash reporting with privacy-safe breadcrumbs.
- Add diagnostics export.
- Add log redaction before support export.
- Add battery and memory profiling on iPad and iPhone.
- Add accessibility pass:
  - Dynamic Type where practical
  - VoiceOver labels
  - keyboard navigation
  - sufficient contrast
- Add release checklist.

Acceptance criteria:

- No known crashers in connection, terminal, or SFTP flows.
- Diagnostics export contains no secrets.
- App runs acceptably on older supported devices.
- App Store metadata, screenshots, and privacy labels are ready.

## Mobile UX Decisions

### iPad Layout

Use `NavigationSplitView`:

- Sidebar: connections and folders.
- Content: terminal workspace, file browser, or editor.
- Detail/Inspector: dashboard, logs, properties, snippets.

For multiple connected servers, use the desktop dashboard idea as an iPad workspace:

- One column per server.
- Each column shows health, UFW, services, and map summary.
- Tap a column to focus the terminal/file browser for that server.

### iPhone Layout

Use a task-first stack:

- Connections
- Server overview
- Terminal
- Files
- Logs
- Snippets
- Settings

Avoid trying to show terminal, file browser, and dashboard at once.

### Terminal Input

Mobile terminal quality will decide whether users keep the app.

Requirements:

- Hardware keyboard shortcuts must be reliable.
- Software accessory keys must be customizable.
- Copy/paste must be explicit and predictable.
- Control key state must be visible.
- Escape and Tab must be reachable without hunting.
- Rotation and split view must preserve terminal size.

## Security Model

Principles:

- Local-first by default.
- No server credentials sent to any `midnight-ssh` service in v1.
- Keychain for passwords, passphrases, and imported private keys.
- Biometric gate for unlocking saved credentials.
- Host-key verification must fail closed, same as desktop.
- Diagnostics must redact hostnames, usernames, keys, tokens, and command output that looks secret.

Future Pro sync:

- Prefer iCloud Keychain or CloudKit with client-side encryption for Apple-only sync.
- For cross-platform sync, build a zero-knowledge vault service only after the mobile apps prove demand.

## App Store Constraints

- Digital feature unlocks in iOS/iPadOS must be available through In-App Purchase.
- Existing web or desktop purchases may be honored in the app only if equivalent purchases are also available through IAP.
- Do not link to external checkout from the app unless using an approved region-specific entitlement and review flow.
- Background SSH should not be marketed as persistent unless implemented within iOS background execution limits.
- Provide App Review with a demo mode or reachable test server.

## Testing Strategy

### Rust

- `cargo test`
- iOS target compile tests.
- Bridge DTO serialization tests.
- Host-key verification tests.
- SFTP operation tests against a local test SSH server.

### Swift

- Shared model unit tests.
- Bridge wrapper tests.
- Keychain tests with simulator-safe fixtures.
- StoreKit configuration tests.
- Terminal lifecycle tests where practical.

### UI

- iPad portrait and landscape.
- iPad split view widths.
- iPhone compact widths.
- Hardware keyboard flow.
- Software keyboard accessory flow.
- Dark and light mode.
- Dynamic Type smoke pass.

### Manual Device Matrix

Minimum recommended:

- Current iPhone.
- Small iPhone screen.
- Current iPad.
- iPad with Magic Keyboard.
- Older supported iPad.

## CI Plan

Add CI jobs:

- Rust workspace tests.
- Rust iOS target builds.
- UniFFI binding generation check.
- iOS simulator build.
- macOS app build to prevent regressions.

Example commands:

```bash
xcodegen generate --spec r-shell-macos/project.yml
xcodebuild \
  -project r-shell-macos/R-Shell.xcodeproj \
  -scheme RShellMobile \
  -destination 'platform=iOS Simulator,name=iPad Pro (11-inch)' \
  -derivedDataPath /tmp/rshell-ios-dd \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Release Strategy

### Internal Alpha

Audience: developer only.

Scope:

- Connect.
- Terminal.
- Keychain.
- Basic profile storage.

### TestFlight Beta 1

Audience: trusted users.

Scope:

- iPad terminal.
- SFTP browser.
- Editor.
- Basic dashboard.

### TestFlight Beta 2

Audience: broader ops/dev users.

Scope:

- iPhone UI.
- StoreKit.
- Diagnostics.
- Polished onboarding.

### App Store v1

Scope:

- iPad-first professional SSH client.
- iPhone incident response companion.
- Free + Pro monetization.

## Implementation Order

1. Prove Rust bridge builds on iOS.
2. Add iOS app target.
3. Extract shared Swift models without renaming the repo.
4. Build iPad connection list and Keychain.
5. Wire terminal.
6. Add SFTP and editor.
7. Add dashboards.
8. Adapt for iPhone.
9. Add StoreKit.
10. Harden, test, and ship TestFlight.

## Open Decisions

- Minimum supported OS: recommend iOS/iPadOS 17.0 or newer unless there is a clear user reason to support older versions.
- Sync v1: recommend no custom cloud sync in v1; use local-only plus import/export first.
- Editor engine: start with UIKit text view; evaluate a code editor dependency only after MVP.
- Mosh support: defer unless background/resume complaints dominate beta feedback.
- Android timing: start only after iPad TestFlight validates demand and the Rust bridge is cleanly platform-neutral.

