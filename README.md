# R-Shell — Lightweight, Fast SSH Client for macOS, Windows & Linux

A modern, lightweight SSH/SFTP/FTP client. The cross-platform build runs on Tauri 2; the macOS build is a native AppKit/SwiftUI app sharing the same Rust core. Uses ~98% less memory than FinalShell (~34 MB vs ~1.7 GB). Installer under 10 MB — 12× smaller.

**Low memory** · **Native speed** · **Multi-protocol** · **Split terminals** · **SFTP file manager** · **GPU monitoring** · **Log viewer** · **Directory sync**

[Why R-Shell?](#-why-r-shell) · [Repository Layout](#-repository-layout) · [Features](#-features) · [Install](#-installation) · [Screenshots](#-screenshots) · [Contributing](CONTRIBUTING.md) · [License](LICENSE)

</div>

---

## 📸 Screenshots

<div align="center">
  <img src="screenshots/app-screenshot.png" alt="R-Shell Application Screenshot" width="100%">
  <p><i>R-Shell — split terminals, file manager, and system monitor in a single window</i></p>
</div>

---

## 🚀 Why R-Shell?

Most popular SSH clients (FinalShell, MobaXterm, Xshell) are built on Java or Electron, which means high memory usage even when idle. R-Shell is built with Rust + Tauri 2, delivering native performance with a fraction of the memory footprint.

### Memory Comparison (Real-World Test)

Both apps running side-by-side on macOS (Apple Silicon, 16 GB RAM), measured with macOS `footprint` (same metric as Activity Monitor):

| App | Technology | Memory | Relative |
|-----|-----------|--------|----------|
| **R-Shell** | Rust + Tauri 2 | **~34 MB** | **1×** |
| FinalShell | Java (Identifier: st) | **~1.7 GB** | **~50×** |

> R-Shell uses approximately **98% less memory** than FinalShell — that's **~1.7 GB saved** for your IDE, browser, and Docker.

### Installer Size Comparison

| Platform | R-Shell | FinalShell | Savings |
|----------|---------|-----------|---------|
| **Windows** | **3.99 MB** | 64 MB | **~16×** smaller |
| **macOS** | **8.13 MB** | 102 MB | **~12×** smaller |

> No bundled JVM, no Chromium — Tauri uses the OS native webview, so the installer stays tiny.

### Why does this matter?

- Developers often keep SSH clients open all day alongside IDEs, browsers, and Docker
- FinalShell alone can consume over 10% of a 16 GB machine's RAM while idle
- Rust's zero-cost abstractions mean low memory without sacrificing features
- No JVM startup overhead — R-Shell launches instantly

---

## 🎯 About

R-Shell is a free, open-source SSH client that combines an interactive terminal, a dual-panel file manager, real-time system & GPU monitoring, and log viewing — all in one VS Code-like workspace. Built with Rust for native performance and minimal resource usage, it's a lightweight alternative to FinalShell, MobaXterm, and Xshell.

- 🚀 **Native Performance** — Rust core, no Electron or JVM. ~34 MB memory footprint vs FinalShell's ~1.7 GB.
- 🍎 **Native macOS App** — A first-class AppKit/SwiftUI client (`r-shell-macos`) using SwiftTerm and the shared Rust core via uniffi.
- 🌍 **Cross-Platform Tauri Build** — A Tauri 2 + React build (`r-shell-tauri`) for macOS, Windows, and Linux.
- 🧩 **Shared Core** — All connection and protocol logic lives in `r-shell-core`, consumed by both frontends.

---

## 📁 Repository Layout

R-Shell is a Cargo + pnpm workspace with one Rust domain crate and two frontends:

```
r-shell/
├── Cargo.toml             # Cargo workspace root
├── package.json           # pnpm workspace root (delegates to r-shell-tauri)
│
├── r-shell-core/          # Rust domain layer — shared by both frontends
│   └── src/
│       ├── ssh/                  # SSH client (russh)
│       ├── sftp_client.rs        # SFTP (russh-sftp)
│       ├── ftp_client.rs         # FTP / FTPS (suppaftp)
│       ├── connection_manager.rs # Thread-safe session lifecycle
│       ├── event_bus.rs          # Typed event channel for async → FFI
│       ├── keychain.rs           # macOS Keychain integration
│       ├── desktop_protocol.rs   # RDP / VNC scaffolding (out of v1)
│       ├── rdp_client.rs
│       └── vnc_client.rs
│
├── r-shell-macos/         # Native macOS app (AppKit + SwiftUI + SwiftTerm)
│   ├── Cargo.toml                # cdylib + staticlib for FFI
│   ├── src/                      # Rust FFI bridge (uniffi)
│   │   ├── bridge.rs
│   │   ├── ffi.rs
│   │   └── lib.rs
│   ├── Sources/RShellMacOS/      # Swift framework — models & stores
│   ├── RShellApp/                # Xcode app target — views, managers
│   │   ├── RShellApp.swift, ContentView.swift, …
│   │   ├── TerminalView.swift, TerminalSessionManager.swift
│   │   ├── FileBrowserPanel.swift, TransferQueueManager.swift
│   │   ├── MonitorPanel.swift, LogPanel.swift, SettingsView.swift
│   │   ├── BridgeManager.swift   # FFI entry point
│   │   ├── KeychainManager.swift
│   │   └── build_cargo.sh        # Xcode build phase: lipo universal lib
│   ├── Package.swift             # SPM wrapper around the Rust static lib
│   ├── project.yml               # XcodeGen manifest (SwiftTerm via SPM)
│   └── Tests/RShellMacOSTests/
│
└── r-shell-tauri/         # Cross-platform Tauri 2 + React build
    ├── package.json              # k-shell frontend
    ├── src/                      # React 19 + TypeScript UI
    ├── src-tauri/                # Tauri commands & websocket PTY server
    ├── docs/, scripts/, tests/
    └── screenshots/
```

The Cargo workspace members are `r-shell-core`, `r-shell-macos`, and `r-shell-tauri/src-tauri`. The pnpm root forwards `dev`, `build`, `tauri`, and `version:*` scripts into `r-shell-tauri`.

---

## ✨ Features

### 🔌 Multi-Protocol Connections
| Protocol | Authentication | Description |
|----------|---------------|-------------|
| **SSH** | Password, Public Key (with passphrase) | Full interactive PTY terminal |
| **SFTP** | Password, Public Key | Standalone file transfer sessions |
| **FTP** | Password, Anonymous | Plain FTP file transfers |
| **FTPS** | Password, Anonymous | FTP over TLS |

- **Connection Manager** — Tree-view sidebar with folders, favorites, tags, drag-and-drop organization
- **Connection Profiles** — Save, import/export (JSON), duplicate, edit saved connections
- **Session Restore** — Automatically reconnects your previous workspace on launch
- **Quick Connect** — Toolbar dropdown with recent connections
- **Auto Reconnect** — Exponential backoff reconnection (up to 5 attempts)

### 💻 Interactive PTY Terminal
- **Full terminal emulation** via xterm.js v5 — supports vim, htop, top, less, and all interactive programs
- **WebSocket streaming** — low-latency bidirectional I/O with flow control (inspired by ttyd)
- **WebGL renderer** — hardware-accelerated rendering with automatic canvas fallback
- **Terminal search** — regex and case-sensitive search with F3 navigation
- **Context menu** — copy, paste, select all, clear, save to file, reconnect
- **IME / CJK input** — full support for Chinese, Japanese, Korean input methods

### 🪟 Split Panes & Tab Groups
- **Split in 4 directions** — Up, Down, Left, Right
- **Recursive grid layout** — unlimited nested splits with resizable panels
- **Tab management** — add, close, duplicate, reorder (drag-and-drop), move between groups
- **Drop zone overlay** — drag tabs onto 5 drop zones (up/down/left/right/center)
- **Keyboard shortcuts** — Ctrl+\ split, Ctrl+1-9 focus group, Ctrl+Tab cycle tabs

### 📁 Dual-Panel File Manager (FileZilla-style)
- **Local + Remote panels** — side-by-side browsing with upload/download buttons
- **Works over SSH, SFTP, FTP, and FTPS** — unified file operations across all protocols
- **File operations** — create, rename, delete, copy files and directories
- **Breadcrumb navigation** — editable address bar with click-to-navigate
- **Sort & filter** — by name, size, date, permissions, owner (ascending/descending)
- **Multi-select** — select multiple files for batch operations
- **Transfer queue** — queued transfers with progress, speed, ETA, cancel, and retry
- **Recursive directory transfer** — uploads/downloads entire directory trees

### 🔄 Directory Synchronization
- **4-step sync wizard** — Configure → Compare → Review → Sync
- **Sync directions** — Local-to-Remote or Remote-to-Local
- **Comparison criteria** — Size, Modified time, or both
- **Diff preview** — per-item checkboxes with upload/download/delete/skip actions
- **Exclude patterns** — skip `.git`, `node_modules`, `.DS_Store`, etc.

### 📊 System Monitoring
- **CPU** — real-time usage percentage with color-coded thresholds
- **Memory & Swap** — total, used, free with percentage bars
- **Disk** — per-mount filesystem usage with progress bars
- **Uptime & Load Average** — at a glance
- **Process Manager** — list processes sorted by CPU/MEM, kill with confirmation
- **Real-time charts** — CPU history and memory area charts (Recharts)

### 🎮 GPU Monitoring
- **NVIDIA** (nvidia-smi) — utilization, memory, temperature, power, fan speed, encoder/decoder
- **AMD** — GPU stats support
- **Multi-GPU** — GPU selector with individual or "all" view
- **History charts** — utilization, memory, temperature over time
- **Temperature thresholds** — color-coded: green < 60°C, yellow < 75°C, orange < 85°C, red ≥ 85°C

### 🌐 Network Monitoring
- **Bandwidth** — per-interface rx/tx bytes per second
- **Latency** — real-time network latency measurements
- **Active connections** — protocol, local/remote address, state, PID
- **Usage charts** — download/upload history

### 📋 Log Monitoring
- **Multi-source** — log files, journalctl services, Docker containers, custom paths
- **Auto-discovery** — automatically finds available log sources on the remote host
- **Level filtering** — ERROR, WARN, INFO, DEBUG, TRACE filter chips
- **Regex search** — with match highlighting
- **Live tail** — configurable refresh interval (1s – 30s)
- **Line numbers + timestamps + level badges** — parsed from common log formats
- **Download** — save log content locally

### 🎨 Appearance & Customization
- **10 terminal color themes** — VS Code Dark, Monokai, Solarized Dark/Light, Dracula, One Dark, Nord, Gruvbox Dark, Tokyo Night, Matrix
- **Dark / Light / Auto** — application theme follows system preference
- **7 font families** — Menlo, JetBrains Mono, Fira Code, Source Code Pro, Consolas, Monaco, Courier New
- **Configurable** — font size, line height, letter spacing, cursor style (block/underline/bar), scrollback (1K–100K lines)
- **Background images** — custom image with opacity, blur, and position controls
- **Terminal transparency** — configurable opacity

### ⌨️ Keyboard Shortcuts
| Shortcut | Action |
|----------|--------|
| `Ctrl+B` | Toggle Connection Manager |
| `Ctrl+J` | Toggle File Browser |
| `Ctrl+M` | Toggle Monitor Panel |
| `Ctrl+Z` | Toggle Zen Mode |
| `Ctrl+\` | Split terminal right |
| `Ctrl+Shift+\` | Split terminal down |
| `Ctrl+1` – `9` | Focus terminal group |
| `Ctrl+W` | Close active tab |
| `Ctrl+Tab` | Next tab |
| `Cmd/Ctrl+F` | Search in terminal |
| `F3` / `Shift+F3` | Find next / previous |

### 🔧 Additional Features
- **VS Code-like layout** — resizable left/right sidebars + bottom panel with 5 layout presets (Default, Minimal, Focus, Full Stack, Zen)
- **Auto-update** — check for updates with download progress and install-and-relaunch
- **Menu bar** — File, Edit, Tools, Connection menus with full keyboard shortcuts
- **Status bar** — active connection name, protocol badge, connection status indicator
- **49 Tauri commands** — comprehensive Rust backend API

---

## 🛠 Tech Stack

### Shared Rust Core (`r-shell-core`) — Why It's Lightweight
- **Rust** (edition 2024) — zero-cost abstractions, no garbage collector, no JVM — this is why R-Shell uses ~34 MB vs FinalShell's ~1.7 GB
- **russh / russh-sftp** — pure Rust SSH & SFTP protocol implementation
- **suppaftp** — FTP / FTPS client
- **tokio** — async runtime with minimal overhead
- **security-framework** — macOS Keychain integration
- **Typed event bus** — single channel routes async PTY output, transfer progress, and monitor updates to either frontend

### Native macOS App (`r-shell-macos`)
- **Swift 5.9 / macOS 11+** — AppKit window shell with SwiftUI views
- **SwiftTerm** (SPM) — native terminal emulator (true color, mouse, alternate screen)
- **uniffi 0.28** — proc-macro mode bindings; Rust enums, records, and errors surface as Swift-native types
- **Universal static lib** — `cargo build` for `aarch64-apple-darwin` + `x86_64-apple-darwin`, `lipo`'d into one `.a`, linked by an Xcode build phase
- **XcodeGen** — `project.yml` regenerates `R-Shell.xcodeproj` deterministically
- **Hardened runtime + Keychain** — credentials stored via Keychain Services, never plaintext

### Cross-Platform Build (`r-shell-tauri`)
- **Tauri 2** — uses the OS native webview instead of bundling Chromium (unlike Electron)
- **tokio-tungstenite** — WebSocket server for PTY streaming to the webview
- **sysinfo** — system stats collection
- **React 19** + **TypeScript** — type-safe modern React
- **Tailwind CSS** — utility-first styling
- **Radix UI / shadcn/ui** — 48+ accessible component primitives
- **xterm.js v5** — terminal emulation with WebGL, search, web-links, fit, overlay addons
- **Recharts** — data visualization for monitoring
- **React Hook Form** — form handling
- **Lucide Icons** — icon set

---

## 📦 Installation

### 🍺 Homebrew (macOS — Recommended)

```bash
brew tap GOODBOY008/tap
brew install --cask r-shell
```

**Update:**

```bash
brew upgrade --cask r-shell
```

### 📥 Download Releases

Download from the [Releases](https://github.com/GOODBOY008/r-shell/releases) page:

| Platform | File |
|----------|------|
| macOS (Apple Silicon) | `r-shell_x.x.x_aarch64.dmg` |
| macOS (Intel) | `r-shell_x.x.x_x64.dmg` |
| Windows | `r-shell_x.x.x_x64-setup.exe` |
| Linux | `r-shell_x.x.x_amd64.AppImage` / `.deb` |

---

## 🚀 Development

### Prerequisites

- Node.js ≥ 18 and pnpm (Tauri build)
- Rust & Cargo, edition 2024 (both builds)
- Xcode 15+ and `brew install xcodegen` (native macOS build only)
- The Rust targets `aarch64-apple-darwin` and `x86_64-apple-darwin` for the universal macOS static library:
  ```bash
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  ```

### Quick Start — Tauri (cross-platform)

The pnpm root delegates into `r-shell-tauri`:

```bash
git clone https://github.com/GOODBOY008/r-shell.git
cd r-shell
pnpm install

pnpm dev          # Vite dev server (web only)
pnpm tauri dev    # Tauri desktop dev
pnpm build && pnpm tauri build   # Production bundle
```

### Quick Start — Native macOS

The native app is driven by XcodeGen and links the Rust core as a universal static library:

```bash
cd r-shell-macos
xcodegen generate         # produces R-Shell.xcodeproj from project.yml
open R-Shell.xcodeproj    # then run the RShellApp scheme

# Or build from the command line:
xcodebuild -project R-Shell.xcodeproj -scheme RShellApp -configuration Release
```

The `Build Rust Library` Xcode build phase invokes `RShellApp/build_cargo.sh`, which compiles `r-shell-macos` for both Apple Silicon and Intel and `lipo`s the result into `target/universal/release/libr_shell_macos.a`.

After changing the FFI surface (`r-shell-macos/src/`), regenerate the Swift bindings:

```bash
cargo build -p r-shell-macos --release --target aarch64-apple-darwin
uniffi-bindgen generate \
  target/aarch64-apple-darwin/release/libr_shell_macos.dylib \
  --language swift \
  --out-dir bindings
```

### Testing

```bash
# Rust workspace (core, macos FFI, tauri backend)
cargo test --workspace

# Tauri frontend
pnpm test                 # Vitest

# Native macOS — via Xcode or:
xcodebuild test -project r-shell-macos/R-Shell.xcodeproj -scheme RShellApp
```

### Version Bumping

The pnpm root forwards version scripts into `r-shell-tauri`:

```bash
pnpm run version:patch   # 1.0.0 → 1.0.1
pnpm run version:minor   # 1.0.0 → 1.1.0
pnpm run version:major   # 1.0.0 → 2.0.0
```

The Cargo workspace shares a single version (`workspace.package.version` in the root `Cargo.toml`), kept in sync with the pnpm version by these scripts.

### macOS Code Signing & Notarization

Gatekeeper on macOS requires the app bundle to be signed before it can run without security warnings. This section covers three signing workflows: zero-config ad-hoc (for local testing), Developer ID (for direct distribution), and notarization (to pass Gatekeeper without the "unidentified developer" prompt). The same workflows apply to both the Tauri build (`r-shell-tauri`) and the native macOS build (`r-shell-macos`); paths in the examples below refer to the Tauri build.

#### Prerequisites

```bash
# Ensure you have Xcode Command Line Tools installed
xcode-select --install
```

#### A. Ad-Hoc Signing (Zero-Config, Local Use Only)

Tauri automatically ad-hoc signs the `.app` bundle during `pnpm tauri build`. No certificate or Apple Developer account is needed. The resulting app runs immediately on your own machine but will trigger Gatekeeper if distributed to others.

```bash
pnpm build && pnpm tauri build
```

The signed `.app` and `.dmg` are written to `src-tauri/target/release/bundle/`.

Verify the ad-hoc signature:

```bash
codesign -dv --verbose=4 src-tauri/target/release/bundle/macos/k-shell.app
# Look for: TeamIdentifier=not set, Signature=adhoc
```

#### B. Developer ID Signing (Direct Distribution)

For distributing outside the Mac App Store, sign with an Apple Developer ID certificate.

**One-time setup:**

```bash
# 1. Enroll in the Apple Developer Program (developer.apple.com)
# 2. In Xcode → Settings → Accounts, add your Apple ID
# 3. Create a Developer ID Application certificate:
#    Xcode → Settings → Accounts → Manage Certificates → "+" → Developer ID Application
# 4. Verify the certificate is in your keychain:
security find-identity -v -p codesigning
# Expected output includes: "Developer ID Application: Your Name (TEAMID)"
```

**Create entitlements files** (if not already present):

`src-tauri/entitlements.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
```

> `allow-unsigned-executable-memory` and `disable-library-validation` are required by Tauri's webview on macOS. The network entitlements allow SSH/FTP outbound and the local WebSocket server.

**Build and sign:**

```bash
# Set environment variables for your signing identity
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"

# Build (Tauri 2 picks up the env var automatically)
pnpm build && pnpm tauri build
```

If you need to re-sign an existing app bundle:

```bash
codesign --force --options runtime --sign "Developer ID Application: Your Name (TEAMID)" \
  --entitlements src-tauri/entitlements.plist \
  src-tauri/target/release/bundle/macos/k-shell.app
```

**Verify the signature:**

```bash
codesign -dvvv src-tauri/target/release/bundle/macos/k-shell.app
# Should show: Authority=Developer ID Application: Your Name (TEAMID)
spctl -a -t exec -vv src-tauri/target/release/bundle/macos/k-shell.app
# Should show: accepted, source=Developer ID
```

#### C. Notarization (Gatekeeper-Compliant Distribution)

Notarization uploads the signed app to Apple for malware scanning. Without it, Gatekeeper shows "cannot be opened because the developer cannot be verified."

**Prerequisites:** `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID` from [appleid.apple.com](https://appleid.apple.com) (App-Specific Password).

```bash
# 1. Build and sign with Developer ID (step B above)
pnpm build && pnpm tauri build

# 2. Create a zip of the signed .app (Apple notarization requires zip format)
ditto -c -k --keepParent \
  src-tauri/target/release/bundle/macos/k-shell.app \
  r-shell-notarize.zip

# 3. Submit for notarization
xcrun notarytool submit r-shell-notarize.zip \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

# 4. Staple the notarization ticket to the app
xcrun stapler staple src-tauri/target/release/bundle/macos/k-shell.app

# 5. Verify
xcrun stapler validate src-tauri/target/release/bundle/macos/k-shell.app
# Should show: The validate action worked!
spctl -a -t exec -vv src-tauri/target/release/bundle/macos/k-shell.app
# Should show: accepted, source=Notarized Developer ID

# 6. Rebuild the .dmg with the stapled app
rm r-shell-notarize.zip
```

> Tauri 2 can automate notarization if you set `APPLE_SIGNING_IDENTITY`, `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID` environment variables. See [Tauri macOS signing docs](https://v2.tauri.app/distribute/sign/macos/).

#### Troubleshooting

| Symptom | Likely Fix |
|---------|-----------|
| `code object is not signed at all` | Run `pnpm tauri build` — ad-hoc signing is automatic |
| `cannot be opened because the developer cannot be verified` | The app needs notarization (step C) or right-click → Open |
| `errSecInternalComponent` during signing | Unlock your keychain: `security unlock-keychain login.keychain` |
| `rustc: symbol(s) not found for target aarch64` | Missing macOS SDK — run `xcode-select --install` |
| `The binary is not signed` (codesign check) | Tauri ad-hoc signs the outer bundle only; this warning on the inner binary is normal |

---

## 📄 License

MIT — see [LICENSE](LICENSE).
