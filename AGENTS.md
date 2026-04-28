# AGENTS.md — AI Agent Guide for R-Shell

## Project Summary

R-Shell is a modern desktop SSH client built with **React 19 + TypeScript** (frontend) and **Tauri 2 + Rust** (backend). It provides interactive terminal sessions, SFTP file management, system monitoring, and multi-tab session management in a VS Code-like layout.

- **Repository**: `GOODBOY008/r-shell`
- **Version**: 1.3.2
- **Package Manager**: pnpm (v9.15.4)
- **Node Target**: ES2020
- **Rust Edition**: 2024

## Workspace Layout

The repo is a Cargo workspace with three crates and one Tauri app:

| Path | Purpose |
|------|---------|
| `r-shell-tauri/` | Existing Tauri desktop app (React + Tauri Rust backend) |
| `r-shell-core/` | Rust domain layer — SSH, PTY, connection management (extracted in Sprint 2) |
| `r-shell-macos/` | Native macOS app — Swift UI + Rust FFI bridge (Sprint 3+) |

All Tauri app source paths below are relative to `r-shell-tauri/` unless noted.

---

## Architecture Overview

### Frontend (React 19 + TypeScript)

| Layer | Location | Purpose |
|-------|----------|---------|
| Entry point | `r-shell-tauri/src/main.tsx` → `r-shell-tauri/src/App.tsx` | App bootstrap, layout, session restoration |
| Feature components | `r-shell-tauri/src/components/*.tsx` | Connection dialog, terminal, SFTP, monitors |
| Terminal subsystem | `r-shell-tauri/src/components/terminal/` | Grid renderer, tab bar, context menu, search, drop zones |
| Terminal addons | `r-shell-tauri/src/components/terminal/addons/` | xterm.js addon wrappers |
| UI primitives | `r-shell-tauri/src/components/ui/` | 48+ shadcn/ui components (Radix-based) |
| Shared logic | `r-shell-tauri/src/lib/` | State management, storage, keyboard shortcuts, layout |
| Styles | `r-shell-tauri/src/index.css`, `r-shell-tauri/src/styles/globals.css` | Tailwind CSS with CSS variable theming |

### Backend (Tauri 2 + Rust)

Domain logic lives in `r-shell-core/`. Tauri commands in `r-shell-tauri/src-tauri/src/commands/` are thin adapters calling into core.

| Module | File | Purpose |
|--------|------|---------|
| SSH client | `r-shell-core/src/ssh/mod.rs` | Connection, auth (password/publickey), PTY, SFTP |
| Connection manager | `r-shell-core/src/connection_manager.rs` | Thread-safe session lifecycle (`Arc<RwLock<HashMap>>`) |
| Keychain | `r-shell-core/src/keychain.rs` | macOS Keychain credential storage |
| SFTP client | `r-shell-core/src/sftp_client.rs` | Standalone SFTP (non-SSH) connection |
| FTP client | `r-shell-core/src/ftp_client.rs` | FTP/FTPS file transfer |
| Event bus | `r-shell-core/src/event_bus.rs` | Broadcast channel for async-to-sync events |
| Tauri commands | `r-shell-tauri/src-tauri/src/commands/` | 27+ IPC command handlers (adapters) |
| WebSocket server | `r-shell-tauri/src-tauri/src/websocket_server.rs` | PTY I/O streaming on port 9001-9010 |
| App setup | `r-shell-tauri/src-tauri/src/lib.rs` | Plugin init, command registration, WS server spawn |

### Native macOS Bridge (Sprint 3+)

The `r-shell-macos/` crate provides the FFI bridge between Rust and Swift.

| Module | File | Purpose |
|--------|------|---------|
| Bridge context | `r-shell-macos/src/bridge.rs` | Tokio runtime + connection manager singleton |
| FFI surface | `r-shell-macos/src/ffi.rs` | uniffi-exported functions and types |
| Build script | `r-shell-macos/build.rs` | Cargo build integration |
| Swift source | `r-shell-macos/Sources/RShellMacOS/RShellMacOS.swift` | SPM target wrapper |
| Swift tests | `r-shell-macos/Tests/RShellMacOSTests/` | XCTest harness for FFI bridge |

The FFI surface uses `uniffi` proc-macros for Swift binding generation.
Generate bindings after FFI changes:

```bash
cargo build -p r-shell-macos --release
uniffi-bindgen generate \
    target/release/lib_r_shell_macos.dylib \
    --language swift \
    --out-dir r-shell-macos/bindings
```

### Communication Model

1. **Tauri Commands** (`invoke()`): Request/response for one-off operations (connect, execute command, file ops, system stats)
2. **WebSocket** (`ws://127.0.0.1:{9001-9010}`): Bidirectional streaming for interactive PTY terminal sessions

The WebSocket protocol uses a tagged `WsMessage` enum:
- `StartPty` / `PtyStarted` — session lifecycle with generation counters
- `Input` / `Output` — terminal data
- `Resize` — terminal dimensions
- `Pause` / `Resume` — flow control
- `Close` — with optional generation to prevent stale-close races

---

## Build & Run

### Root-Level Commands (delegate to `r-shell-tauri/`)

```bash
# Install dependencies
pnpm install --prefix r-shell-tauri

# Frontend dev server only (port 1420)
pnpm dev

# Full desktop app with hot reload
pnpm tauri dev

# Production build
pnpm build && pnpm tauri build
```

You can also run commands directly inside `r-shell-tauri/`:

```bash
cd r-shell-tauri
pnpm install
pnpm dev
pnpm tauri dev
```

### Testing

```bash
# Rust unit tests (entire workspace)
cargo test

# Rust unit tests (specific crate)
cargo test -p k-shell
cargo test -p r-shell-core
cargo test -p r-shell-macos

# E2E tests
pnpm test:e2e
```

### Linting

```bash
# Check for lint errors
pnpm lint

# Auto-fix fixable issues
pnpm lint:fix
```

- Config: `r-shell-tauri/eslint.config.js` — ESLint v10 flat config with `typescript-eslint` (type-aware)
- Plugins: `react-hooks` (v7), `react-refresh`
- Test files (`r-shell-tauri/src/__tests__/`, `r-shell-tauri/src/components/__tests__/`, `r-shell-tauri/src/lib/__tests__/`) are excluded from linting
- shadcn/ui components (`r-shell-tauri/src/components/ui/`) have relaxed rules
- `no-unsafe-*` rules are warnings (common with `invoke()` returning unknown)
- `react-hooks/set-state-in-effect`, `react-hooks/refs`, `react-hooks/purity` are warnings (new v7 rules)

- Frontend tests live in `r-shell-tauri/src/__tests__/` and `r-shell-tauri/src/components/__tests__/` and `r-shell-tauri/src/lib/__tests__/`
- Test config: `r-shell-tauri/vitest.config.ts` — uses jsdom environment, globals enabled
- Pattern: `r-shell-tauri/src/**/*.test.ts` and `r-shell-tauri/src/**/*.test.tsx`
- Property-based tests use `fast-check`

### Version Bumping

```bash
pnpm run version:patch   # 0.7.1 → 0.7.2
pnpm run version:minor   # 0.7.1 → 0.8.0
pnpm run version:major   # 0.7.1 → 1.0.0
```

Updates `r-shell-tauri/package.json`, `r-shell-tauri/src-tauri/Cargo.toml`, `Cargo.lock`, `r-shell-tauri/src-tauri/tauri.conf.json`, `CHANGELOG.md` and creates a git commit.

---

## Key Files & Entry Points

| What | Where |
|------|-------|
| App entry & layout | `r-shell-tauri/src/App.tsx` (1074 lines) |
| Tauri commands | `r-shell-tauri/src-tauri/src/commands.rs` (1705 lines) |
| SSH implementation | `r-shell-core/src/ssh/mod.rs` |
| Connection manager | `r-shell-core/src/connection_manager.rs` |
| WebSocket server | `r-shell-tauri/src-tauri/src/websocket_server.rs` |
| macOS bridge | `r-shell-macos/src/bridge.rs`, `r-shell-macos/src/ffi.rs` |
| Terminal group state | `r-shell-tauri/src/lib/terminal-group-reducer.ts`, `terminal-group-types.ts` |
| Terminal group serialization | `r-shell-tauri/src/lib/terminal-group-serializer.ts` |
| Connection storage | `r-shell-tauri/src/lib/connection-storage.ts` |
| Layout system | `r-shell-tauri/src/lib/layout-context.tsx`, `r-shell-tauri/src/lib/layout-config.ts` |
| Keyboard shortcuts | `r-shell-tauri/src/lib/keyboard-shortcuts.ts` |
| PTY terminal component | `r-shell-tauri/src/components/pty-terminal.tsx` |
| Terminal grid | `r-shell-tauri/src/components/terminal/grid-renderer.tsx` |
| Tauri config | `r-shell-tauri/src-tauri/tauri.conf.json` |
| Rust module root | `r-shell-tauri/src-tauri/src/lib.rs` |

---

## Coding Conventions

### TypeScript / React

- **Components**: PascalCase (`PtyTerminal`, `GridRenderer`, `ConnectionDialog`)
- **Files**: kebab-case (`pty-terminal.tsx`, `grid-renderer.tsx`)
- **Path alias**: `@/*` maps to `./src/*` (configured in `tsconfig.json` and `vite.config.ts`)
- **Styling**: Tailwind CSS with `cn()` utility from `src/lib/utils.ts` for conditional class merging
- **UI components**: shadcn/ui pattern — Radix UI primitives + `class-variance-authority` for variants
- **State management**: React context + `useReducer` for terminal groups; localStorage for persistence
- **Error display**: `toast.error()` / `toast.success()` from `sonner` library
- **Forms**: `react-hook-form`
- **Icons**: `lucide-react`
- **Terminal**: xterm.js v5 with addons (fit, search, web-links, webgl/canvas, image, unicode11, clipboard)

### Rust

- **Structs**: PascalCase (`ConnectionManager`, `SshClient`, `WsMessage`)
- **Modules**: snake_case (`connection_manager`, `websocket_server`)
- **Commands**: snake_case with `#[tauri::command]` attribute (`ssh_connect`, `get_system_stats`)
- **Serialization**: `serde` with `Serialize`/`Deserialize` derives; tagged enums via `#[serde(tag = "type")]`
- **Error handling**: `anyhow::Result<T>` internally; `Result<Response, String>` for Tauri command returns
- **Async runtime**: Tokio with full features
- **Thread safety**: `Arc<RwLock<HashMap>>` pattern for shared state; `CancellationToken` for cancellation
- **Logging**: `tracing` crate (initialized in `lib.rs`)
- **macOS FFI**: `uniffi` proc-macros in `r-shell-macos/src/ffi.rs`. Swift bindings generated via `uniffi-bindgen` from the compiled cdylib. All FFI functions are synchronous from Swift's perspective (internal `block_on` on the bridge's Tokio runtime).

### Adding a New Tauri Command

1. Define the function in `r-shell-tauri/src-tauri/src/commands.rs` with `#[tauri::command]`
2. Register it in `r-shell-tauri/src-tauri/src/lib.rs` inside `tauri::generate_handler![...]`
3. Call from React: `await invoke('command_name', { params })`

---

## State & Data Flow

### Terminal Group Architecture

Terminal sessions use a reducer-based architecture:

- **Types**: `r-shell-tauri/src/lib/terminal-group-types.ts` — `TerminalGroup`, `TerminalTab`, `TerminalGroupState`
- **Reducer**: `r-shell-tauri/src/lib/terminal-group-reducer.ts` — actions like `ADD_TAB`, `REMOVE_TAB`, `SPLIT_GROUP`, `ACTIVATE_TAB`, `MOVE_TAB`
- **Context**: `r-shell-tauri/src/lib/terminal-group-context.tsx` — `TerminalGroupProvider` + `useTerminalGroups()` hook
- **Serializer**: `r-shell-tauri/src/lib/terminal-group-serializer.ts` — persist/restore terminal layout to localStorage
- **Renderer**: `r-shell-tauri/src/components/terminal/grid-renderer.tsx` — renders the recursive group tree

### Connection Lifecycle

1. User fills `ConnectionDialog` → `invoke('ssh_connect', { request })` → Rust `ConnectionManager::create_connection()`
2. SSH client authenticates via `russh` (password or public key)
3. Connection stored in `ConnectionManager.connections` HashMap
4. For interactive terminal: frontend sends `StartPty` via WebSocket → Rust opens PTY channel → bidirectional streaming
5. Disconnect: `invoke('ssh_disconnect')` → cleanup in both connection and PTY maps

### Session Restoration

On startup, `App.tsx` reads active sessions from `ConnectionStorageManager` and reconnects sequentially with progress tracking. Failed reconnections show toasts but don't block others.

---

## Layout System

VS Code-like resizable panel layout with presets:

- **Presets**: Default, Minimal, Focus Mode, Full Stack, Zen
- **Keyboard shortcuts**: `Ctrl+B` (left sidebar), `Ctrl+J` (bottom panel), `Ctrl+M` (right sidebar), `Ctrl+Z` (zen mode)
- **Persistence**: Panel sizes auto-saved to localStorage per panel group
- **Implementation**: `react-resizable-panels` library

---

## Dependencies Summary

### Frontend (Key)
| Package | Purpose |
|---------|---------|
| `@tauri-apps/api` | Tauri IPC bridge |
| `@xterm/xterm` + addons | Terminal emulator |
| `@radix-ui/*` | Accessible UI primitives |
| `react-resizable-panels` | Resizable layout panels |
| `recharts` | Monitoring charts |
| `sonner` | Toast notifications |
| `react-hook-form` | Form handling |
| `next-themes` | Dark/light theme support |
| `lucide-react` | Icons |

### Backend (Key)
| Crate | Purpose |
|-------|---------|
| `tauri` | Desktop app framework |
| `russh` / `russh-keys` | SSH protocol |
| `russh-sftp` | SFTP file operations |
| `tokio` | Async runtime |
| `tokio-tungstenite` | WebSocket server |
| `tokio-util` | CancellationToken, utilities |
| `serde` / `serde_json` | Serialization |
| `anyhow` / `thiserror` | Error handling |
| `tracing` | Logging |

---

## Common Pitfalls & Notes

1. **WebSocket port is dynamic**: The server tries ports 9001–9010 and stores the bound port in a global `AtomicU16`. Frontend retrieves it via `get_websocket_port` command.
2. **PTY generation counters**: Each `StartPty` increments a generation counter. `Close` messages include the generation to prevent stale closes from killing newly created sessions (important for React component remounting).
3. **Connection cancellation**: Pending connections can be cancelled via `CancellationToken`. Always clean up pending state.
4. **Path alias**: Use `@/` imports in TypeScript (resolves to `r-shell-tauri/src/`). Configured in both `r-shell-tauri/tsconfig.json` and `r-shell-tauri/vite.config.ts`.
5. **Server key verification**: SSH and standalone SFTP use a TOFU host-key store at `$XDG_CONFIG_HOME/r-shell/known_hosts` (via `HostKeyStore`). Known keys must match, unknown keys are persisted on first trust, and unreadable or unwritable trust-store state now fails closed instead of silently accepting the server key.
6. **ESLint configured (v10 flat config)**: `eslint.config.js` uses `typescript-eslint` with type-aware checking, `react-hooks` v7, and `react-refresh`. Run `pnpm lint` to check, `pnpm lint:fix` to auto-fix. Test files and `src/components/ui/` are excluded or relaxed. Warnings are intentional for `no-unsafe-*` (Tauri invoke), `no-floating-promises` (fire-and-forget), and new react-hooks v7 rules (`set-state-in-effect`, `refs`, `purity`). When adding unused function parameters, prefix with `_`. When renaming destructured props to suppress unused warnings, use `{ propName: _propName }` syntax to keep the interface key intact.
7. **`editor/` directory is empty**: `src-tauri/src/editor/` exists but contains no files — reserved for future use.
8. **Release profile**: Rust release builds use LTO, single codegen unit, and symbol stripping for maximum optimization.
9. **Radix Dialog centering in Tauri**: The base `DialogContent` from shadcn/ui uses `top-[50%] translate-y-[-50%]` centering. When a dialog is tall, this pushes its top half above the Tauri window viewport (there's no browser chrome to scroll to). **Always override** tall or variable-height dialogs with `!inset-0 !m-auto` centering instead, which keeps the dialog fully within the viewport.
10. **Never use `h-fit` on a flex parent that has `flex-1` children**: `h-fit` makes the container size to its content, leaving zero remaining space for `flex-1` children to fill — they collapse to zero height and become invisible. When a dialog needs to grow to show dynamic content (e.g., comparison results in a scrollable area), use an explicit height like `h-[85vh]` so `flex-1` children have space to occupy. Use conditional height if the dialog should be compact when content is absent: `` `${hasContent ? "!h-[85vh]" : "!h-fit"}` ``.
11. **IME / Input Method & keyboard input in xterm.js terminals**: Three rules to prevent swallowed keystrokes (Space, characters during fast typing, CJK composition):
    - **`attachCustomKeyEventHandler` must bail out during composition**: Always add `if (event.isComposing || event.keyCode === 229) return true;` as the very first check. Returning `true` hands the event to xterm's built-in `CompositionHelper`, which correctly manages the composition lifecycle. Without this, the custom handler can race with IME candidate selection (e.g. pressing Space to confirm a Chinese character) and swallow or duplicate input. VS Code's terminal does the same early-return.
    - **Never `preventDefault()` on keys that reach xterm's textarea**: React 18's event delegation registers a capture-phase listener on the root DOM node, which fires *before* xterm's own capture handler on its hidden `<textarea>`. If any ancestor React `onKeyDown` handler calls `e.preventDefault()` on Space or Enter, the browser will never insert the character into the textarea, breaking both direct input and IME paths (`_handleAnyTextareaChanges` checks the textarea value via `setTimeout(0)` — if the value didn't change, the character is lost). When adding `onKeyDown` to a wrapper around a terminal, always guard: `if (target.tagName === 'TEXTAREA' || target.closest('.xterm')) return;`
    - **Avoid per-keystroke overhead in `onData`**: Do not put `console.log()` or allocate objects (e.g. `new TextEncoder()`) inside the `onData` handler. In Tauri's WKWebView, `console.log` crosses the native bridge (~1–3 ms), and during fast typing (>10 chars/s) the accumulated latency pushes the JS event loop behind, causing dropped characters and IME desynchronisation. Hoist allocations outside the closure and remove hot-path logging.

---

## Debugging

- **Frontend**: React DevTools + browser console; Vite HMR on port 1420
- **Backend**: Terminal logs via `tracing` (initialized in `r-shell-tauri/src-tauri/src/lib.rs`)
- **WebSocket**: Monitor in browser Network tab — filter for `ws://127.0.0.1:9001`
- **Rust errors**: Vite `clearScreen: false` prevents obscuring Rust compile errors
