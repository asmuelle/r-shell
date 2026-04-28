# R-Shell command surface — cross-stack helpers for the Cargo + pnpm
# workspace.
#
# Install `just` once: `brew install just`. Run `just` (no args) to see all
# recipes. Naming convention:
#
#   <verb>          — workspace-wide (e.g. `check`, `test`, `fmt`)
#   tauri-<verb>    — Tauri build (`r-shell-tauri`)
#   mac-<verb>      — native macOS build (`r-shell-macos`)
#   version-<level> — semver bump propagated to Cargo + pnpm versions

set shell := ["bash", "-euc"]
set dotenv-load := false

# Paths
tauri_dir   := "r-shell-tauri"
macos_dir   := "r-shell-macos"
xcode_proj  := macos_dir + "/R-Shell.xcodeproj"
mac_scheme  := "RShellApp"
mac_build   := macos_dir + "/build"
mac_app     := mac_build + "/Build/Products/Release/R-Shell.app"
universal   := "target/universal/release/libr_shell_macos.a"


# ─── default: list recipes ──────────────────────────────────────────────

default:
    @just --list --unsorted


# ─── workspace ──────────────────────────────────────────────────────────

# Install Node deps and one-time prerequisites for both frontends.
bootstrap: tauri-install mac-bootstrap
    @echo "✅ Workspace bootstrapped"

# Cargo check across the whole workspace (faster than build).
check:
    cargo check --workspace --all-targets

# Run all Rust tests + the Tauri Vitest suite.
test: test-rust tauri-test

test-rust:
    cargo test --workspace

# Format Rust + (best-effort) JS/TS via the Tauri build's tooling.
fmt:
    cargo fmt --all
    cd {{tauri_dir}} && pnpm lint:fix || true

# Strict lint pass — fails CI if anything is off.
lint:
    cargo fmt --all --check
    cargo clippy --workspace --all-targets -- -D warnings
    cd {{tauri_dir}} && pnpm lint

# Wipe Cargo + Tauri + macOS build artifacts.
clean:
    cargo clean
    rm -rf {{mac_build}}
    rm -rf {{tauri_dir}}/dist
    @echo "✅ Cleaned build artifacts"


# ─── tauri build (cross-platform) ───────────────────────────────────────

# Install pnpm dependencies for the Tauri frontend.
tauri-install:
    cd {{tauri_dir}} && pnpm install

alias dev := tauri-dev

# Vite dev server (web only — no Tauri shell).
tauri-dev:
    cd {{tauri_dir}} && pnpm dev

# Tauri desktop dev (full app).
tauri-shell:
    cd {{tauri_dir}} && pnpm tauri dev

# Production Tauri bundle (writes to {{tauri_dir}}/src-tauri/target/release/bundle).
tauri-build:
    cd {{tauri_dir}} && pnpm build && pnpm tauri build

# Frontend unit tests (Vitest).
tauri-test:
    cd {{tauri_dir}} && pnpm test


# ─── native macOS build ─────────────────────────────────────────────────

# One-time prerequisites for the native macOS build.
mac-bootstrap:
    @command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
    rustup target add aarch64-apple-darwin x86_64-apple-darwin
    @echo "✅ macOS prereqs installed"

# Regenerate R-Shell.xcodeproj from project.yml. Run after editing project.yml.
mac-gen:
    cd {{macos_dir}} && xcodegen generate

# Build the universal Rust static lib (lipo'd, no Xcode link step).
mac-rust:
    cargo build -p r-shell-macos --release --target aarch64-apple-darwin
    cargo build -p r-shell-macos --release --target x86_64-apple-darwin
    mkdir -p target/universal/release
    lipo -create \
        target/aarch64-apple-darwin/release/libr_shell_macos.a \
        target/x86_64-apple-darwin/release/libr_shell_macos.a \
        -output {{universal}}
    @echo "✅ Universal static lib: {{universal}}"

# Ad-hoc signed .app build (Release default; pass Debug to switch).
mac-build config="Release":
    @just _ensure-xcodeproj
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{mac_scheme}} \
        -configuration {{config}} \
        -derivedDataPath {{mac_build}} \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES \
        build
    @echo "✅ Built {{mac_app}}"

# Build with a real Developer ID (requires APPLE_SIGNING_IDENTITY env).
mac-build-signed:
    @just _ensure-xcodeproj
    @test -n "${APPLE_SIGNING_IDENTITY:-}" || (echo "❌ APPLE_SIGNING_IDENTITY not set"; exit 1)
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{mac_scheme}} \
        -configuration Release \
        -derivedDataPath {{mac_build}} \
        CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" \
        build

# Open the most recently built .app.
mac-run:
    @test -d {{mac_app}} || (echo "❌ {{mac_app}} not found — run 'just mac-build' first"; exit 1)
    open {{mac_app}}

# xcodebuild test — runs both the framework scheme (pure-Swift unit
# tests over RShellMacOS models + helpers) and the app scheme (FFI
# integration tests that exercise the uniffi bindings inside the app's
# process).
mac-test:
    @just _ensure-xcodeproj
    xcodebuild test \
        -project {{xcode_proj}} \
        -scheme RShellMacOS \
        -destination 'platform=macOS'
    xcodebuild test \
        -project {{xcode_proj}} \
        -scheme RShellApp \
        -destination 'platform=macOS' \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES

# Verify the .app's signature & Gatekeeper status.
mac-verify:
    @test -d {{mac_app}} || (echo "❌ {{mac_app}} not found"; exit 1)
    codesign -dv --verbose=4 {{mac_app}} 2>&1 | grep -E '(Identifier|Authority|Signature|TeamIdentifier)' || true
    @echo "---"
    codesign --verify --deep --strict --verbose=2 {{mac_app}}
    @echo "---"
    spctl -a -t exec -vv {{mac_app}} || true

# Regenerate Swift FFI bindings (run after changing r-shell-macos/src/).
# Uses the crate-local uniffi-bindgen bin so the version is pinned to the
# crate's uniffi dependency — no global install drift.
mac-bindings:
    cargo build -p r-shell-macos --release --lib
    cargo run -p r-shell-macos --release --bin uniffi-bindgen -- \
        generate \
        --library target/release/libr_shell_macos.dylib \
        --language swift \
        --out-dir {{macos_dir}}/bindings
    # Swift auto-discovers `module.modulemap` along SWIFT_INCLUDE_PATHS;
    # the uniffi-named file would be ignored, so rename in place.
    mv -f {{macos_dir}}/bindings/r_shell_macosFFI.modulemap \
          {{macos_dir}}/bindings/module.modulemap
    @echo "✅ Swift bindings written to {{macos_dir}}/bindings/"

# Package the built .app as a DMG.
mac-dmg:
    @test -d {{mac_app}} || (echo "❌ {{mac_app}} not found — run 'just mac-build' first"; exit 1)
    {{macos_dir}}/RShellApp/build_dmg.sh {{mac_app}}

# Open R-Shell.xcodeproj in Xcode.
mac-open:
    @just _ensure-xcodeproj
    open {{xcode_proj}}

# Clean only macOS build outputs (keeps the Tauri target).
mac-clean:
    rm -rf {{mac_build}}
    rm -rf target/universal
    rm -rf target/aarch64-apple-darwin target/x86_64-apple-darwin
    @echo "✅ macOS build artifacts cleaned"


# ─── version bumping ────────────────────────────────────────────────────

# Bump patch (1.2.3 → 1.2.4) across Cargo + pnpm.
version-patch:
    cd {{tauri_dir}} && pnpm version:patch

# Bump minor (1.2.3 → 1.3.0).
version-minor:
    cd {{tauri_dir}} && pnpm version:minor

# Bump major (1.2.3 → 2.0.0).
version-major:
    cd {{tauri_dir}} && pnpm version:major


# ─── private helpers ────────────────────────────────────────────────────

_ensure-xcodeproj:
    @test -d {{xcode_proj}} || just mac-gen
