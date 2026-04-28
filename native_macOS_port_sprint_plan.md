# Native macOS Port Sprint Plan

## Assumptions

- Sprint length: `2 weeks`
- Team: `2 engineers` full-time
- Scope rule: `RDP/VNC is out of v1 scope`
- Team split:
  - Engineer 1: `r-shell-macos`
  - Engineer 2: `r-shell-core` and `r-shell-tauri` adapter work
- With one engineer, keep the sequence but expect roughly `1.7x to 2x` the calendar time

## Sprint Plan

### Sprint 1

**Goal:** Stabilize the repo for parallel migration work.

**Tickets:**

- Create top-level `r-shell-core`, `r-shell-tauri`, and `r-shell-macos`
- Move the current React/Tauri app under `r-shell-tauri`
- Add root `Cargo.toml`, root scripts, and workspace docs
- Preserve current build, test, and release behavior
- Set up Apple Developer team, register bundle ID, create signing certificates and provisioning profiles
- Create `r-shell-macos` SPM package skeleton that wraps a Rust static library via a `cargo build` build-phase script

**Acceptance:**

- The existing app still builds and runs from the new layout
- The repo has one documented bootstrap path

### Sprint 2

**Goal:** Extract the Rust domain layer without breaking the Tauri app.

**Tickets:**

- Move SSH, PTY lifecycle, host-key handling, connection manager, SFTP, and FTP services out of `src-tauri` into `r-shell-core`
- Keep Tauri commands as adapters
- Add integration tests for connect, disconnect, PTY start/close, and file listing
- Document thread-safety requirements for every public API: annotate which methods are `Send + Sync`, which must run on the Tokio runtime, and which can be called from any thread
- Add an event bus module to `r-shell-core` — typed events on a channel, consumed by a single FFI callback. All async-to-sync boundary crossings (PTY output, transfer progress, monitor updates) route through it.

### Sprint 3

**Goal:** Define the native bridge contract.

**Tickets:**

- Choose FFI tooling: use `uniffi` (proc-macro mode). It generates Swift-native enums, records, and error types from Rust source. Avoid `extern "C"` (too manual) and `cxx` (Swift can't consume C++).
- Define the shared protocol types in `rshell-protocol`: connection params, PTY events, file ops, monitor/log payloads, and a C-compatible `RustResult<T>` struct (`{ ok: bool, data: Vec<u8>, error: String }`)
- Design the async-FFI pattern:
  - **Actions** (connect, disconnect, resize, file ops): Swift calls a sync FFI function; Rust spawns a Tokio task, returns a `u64` handle; completion arrives via the event bus callback
  - **Streams** (PTY output, transfer progress): Rust pushes events to the event bus channel; a single registered FFI callback delivers them to Swift on a background dispatch queue
- Implement `rshell-swift-ffi` using `uniffi`:
  - Action functions for connect/disconnect/command/file ops
  - PTY functions (start, write, resize, close)
  - Event bus — one `set_event_callback` function; Rust calls it with serialized events
  - `RustResult` error type mapped to Swift `Error` via uniffi
- Build a minimal Swift test harness (macOS command-line tool) that links the Rust static lib and proves: connect, PTY start, write, read output, disconnect
- Set up the Xcode build phase to run `uniffi-bindgen` and `cargo build` automatically

**Acceptance:**

- A minimal native test host can connect to SSH, start a PTY, send input, and read output without Tauri
- Errors from Rust (connection refused, auth failure, host key mismatch) surface as typed Swift errors
- The FFI surface is frozen — no new functions added without revisiting this contract

### Sprint 4

**Goal:** Stand up the macOS app shell.

**Tickets:**

- Create `r-shell-macos` Xcode project that depends on the SPM package from Sprint 1
- Wire the SPM build phase: `cargo build --release` for `aarch64-apple-darwin` + `x86_64-apple-darwin`, `lipo` into a universal static lib
- Add app lifecycle, window, menus, settings shell, and AppKit split-view host
- Initialize the Rust core on launch — call init via FFI, spawn a background Tokio runtime, register the event bus callback
- Wire error handling using the `RustResult` pattern from Sprint 3: all FFI errors display as Swift-native `Error` values via uniffi's generated bindings
- Add structured logging (os_log) for bridge init, FFI calls, and event bus traffic

**Acceptance:**

- The macOS app launches, opens its main window, and initializes the bridge reliably
- Builds for both `arm64` and `x86_64` from a single Xcode invocation

### Sprint 5

**Goal:** Rebuild navigation and layout in native UI.

**Tickets:**

- Implement sidebar, center workspace, bottom panel, and right inspector
- Add native tab and split-group models
- Persist layout via `Codable` + `Application Support` directory (JSON file); restore on relaunch
- Wire core keyboard shortcuts

**Acceptance:**

- Users can open, focus, close, and restore tabs and split panes
- Layout state survives relaunch

### Sprint 6

**Goal:** Restore connection management with proper native persistence.

**Tickets:**

- Port saved connections and folder hierarchy from the current localStorage model
- Move passwords and passphrases to Keychain (uses `keychain-access-groups` entitlement already set up in Sprint 1)
- Implement one-time import from the Tauri app
- Wire host-key prompts and trust flows

**Acceptance:**

- Existing users can import profiles and reconnect after restart
- No plaintext credentials are stored in app-local state

### Sprint 7

**Goal:** Ship the first usable native terminal.

**Tickets:**

- Run a SwiftTerm capability audit before integration: verify true-color, 256-color, mouse tracking, alternate screen, and Sixel/image support against what xterm.js currently provides. Document gaps.
- Integrate `SwiftTerm` via SPM
- Bind PTY streams: Swift input → `write()` FFI call; Rust output → event bus callback → `feed(byteArray:)` on a background dispatch queue
- Batch PTY output writes: accumulate in a ring buffer, flush on 50ms timer or 16KB threshold to minimize FFI overhead per character
- Implement copy/paste, selection, links, theming, resize, reconnect, and tab focus behavior
- Cover the main shell workflows with smoke tests

**Acceptance:**

- Internal users can run `vim`, `less`, `tmux`, and normal interactive shells without falling back to the Tauri app

### Sprint 8

**Goal:** Close terminal parity gaps and make it fit for daily use.

**Tickets:**

- Fix IME/input edge cases (SwiftTerm's composition model differs from xterm.js — test CJK, Emoji, dead keys explicitly)
- Fix scrollback behavior, search, and performance issues
- Add profiling around PTY streaming and rendering — measure FFI call latency per batch, batch flush frequency, and rendering frame times
- Profile batch sizes vs. latency: tune the flush timer/threshold from Sprint 7 based on real workloads (`yes`, `cat largefile`, `tmux` resize)
- Close the top bug tail from Sprint 7

**Acceptance:**

- The terminal is stable enough for an internal dogfood week

### Sprint 9

**Goal:** Deliver native file workflows.

**Tickets:**

- Implement local and remote browser views with AppKit table or outline views
- Add upload, download, rename, delete, create directory, drag/drop, transfer queue, and Finder integration
- Wire remote file open, edit, and save for text files

**Acceptance:**

- The file browser covers the current core workflows with no blocker gaps

### Sprint 10

**Goal:** Port monitors and logs.

**Tickets:**

- Rebuild system monitor, process view, log viewer, and chart surfaces in SwiftUI
- Wire polling and refresh
- Add search, tail, and export behavior

**Acceptance:**

- A user can inspect stats and logs natively with comparable usefulness to the current Tauri app

### Sprint 11

**Goal:** Beta hardening.

**Tickets:**

- Complete signing and notarization (certificates and entitlements already set up in Sprint 1, now verify hardened runtime, gatekeeper, and notarization pass fully)
- Packaging (DMG + Sparkle or equivalent for updates)
- Crash/error reporting, migration telemetry, smoke tests, and parity bug triage
- Remove or hide incomplete features that are not v1-ready

**Acceptance:**

- The native app can be handed to internal beta users as the primary macOS build

### Sprint 12

**Goal:** Soak, fix, and decide release readiness.

**Tickets:**

- Run a bug-fix sprint driven by beta feedback
- Perform performance cleanup
- Polish layout, persistence, and terminal behavior
- Write the release checklist and rollback plan

**Acceptance:**

- Blocker count is near zero
- The team can make a yes/no release call with evidence instead of guesswork

## Critical Path

The real schedule driver is:

- `Sprint 2 -> Sprint 3 -> Sprint 4 -> Sprint 5 -> Sprint 7 -> Sprint 8 -> Sprint 11`

Two hidden gates within this path:

1. **Sprint 3 FFI correctness**: If the async-FFI pattern (callback-based event bus + uniffi bindings) is wrong, every downstream sprint pays the cost. Build the test harness first; freeze the FFI surface before Sprint 4 begins.
2. **SwiftTerm capability gaps**: The Sprint 7 audit may reveal features xterm.js has that SwiftTerm lacks (advanced link detection, Sixel, search UI). If gaps are blockers, schedule native reimplementation work before Sprint 7 completes.

The terminal is the hardest part of the project. File browser, monitors, and polish can overlap partially, but a weak terminal slips the release.

## Parallel Work

- `Sprint 5` and `Sprint 6` can overlap
- SwiftTerm capability audit can start in Sprint 6 (research-only, no integration code) to unblock Sprint 7
- `Sprint 9` can start before `Sprint 8` fully ends if the terminal API is already stable
- `Sprint 10` can run mostly in parallel with late file-browser work
- `RDP/VNC` should stay on a separate roadmap branch and not consume v1 capacity

## Definition Of Done For v1

- `r-shell-macos` replaces the current macOS usage for SSH terminal, saved connections, session restore, SFTP/FTP browsing, logs, and monitors
- `r-shell-tauri` still exists during migration, but it is no longer the preferred macOS client
- `r-shell-core` owns all connection and protocol logic

## Rough Calendar

- With two engineers: about `24 weeks` to a serious internal beta and `26 to 28 weeks` to a cleaner release candidate
- With one engineer: plan for `9 to 12 months`

## Next Artifact

The next useful artifact is a ticket board with `epic`, `story`, `owner`, `estimate`, and `dependency` fields for each sprint.
