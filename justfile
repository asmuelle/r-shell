# midnight-ssh command surface — cross-stack helpers for the Cargo + pnpm
# workspace.
#
# Install `just` once: `brew install just`. Run `just` (no args) to see all
# recipes. Naming convention:
#
#   <verb>          — workspace-wide (e.g. `check`, `test`, `fmt`)
#   tauri-<verb>    — Tauri build (`r-shell-tauri`)
#   mac-<verb>      — native macOS build (`r-shell-macos`)
#   ios-<verb>      — native iOS/iPadOS build (`r-shell-macos`)
#   version-<level> — semver bump propagated to Cargo + pnpm versions

set shell := ["bash", "-euc"]
set dotenv-load := false

# Paths
tauri_dir   := "r-shell-tauri"
macos_dir   := "r-shell-macos"
xcode_proj  := macos_dir + "/R-Shell.xcodeproj"
mac_scheme  := "RShellApp"
ios_scheme  := "RShellMobile"
ios_bundle  := "com.r-shell.mobile"
ios_sim_dd  := "/private/tmp/rshell-ios-dd"
ios_sim_app := ios_sim_dd + "/Build/Products/Debug-iphonesimulator/midnight-ssh.app"
mac_build   := macos_dir + "/build"
mac_app     := mac_build + "/Build/Products/Release/midnight-ssh.app"
universal   := "target/universal/release/libr_shell_macos.a"


# ─── default: list recipes ──────────────────────────────────────────────

default:
    @just --list --unsorted


# ─── workspace ──────────────────────────────────────────────────────────

# Install Node deps and one-time prerequisites for all frontends.
bootstrap: tauri-install mac-bootstrap ios-bootstrap
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

# Local equivalent of the GitHub Actions checks that do not need secrets.
ci-local: check test-rust tauri-test tauri-build mac-ci-build ios-ci-build
    @echo "✅ Local CI checks completed"

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

# CI-style app build without signing. Use this for compiler validation
# in environments without a Developer ID certificate.
mac-ci-build:
    @just _ensure-xcodeproj
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{mac_scheme}} \
        -destination 'platform=macOS' \
        -derivedDataPath /private/tmp/rshell-dd \
        CODE_SIGNING_ALLOWED=NO \
        build

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
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        build

# Build and open the native macOS app. Rebuilding here keeps app-icon
# changes and asset-catalog updates visible when using `just mac-run`
# as the normal launch command.
mac-run:
    @just mac-build
    touch {{mac_app}}
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R {{mac_app}}
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
    bash {{macos_dir}}/RShellApp/build_dmg.sh {{mac_app}}

# Build a local release bundle: clean build, DMG, checksum, release notes,
# and an optional notarization pass when Apple credentials are available.
mac-release notarize="false":
    {{macos_dir}}/scripts/mac_release.sh "{{notarize}}"

# Print the Sparkle EdDSA public key for Info.plist. Run once after the
# Swift package has resolved, then keep the private key safe in Keychain.
mac-sparkle-keygen:
    "$({{macos_dir}}/scripts/find_sparkle_tool.sh generate_keys)"

# Generate a Sparkle appcast from a folder that contains release DMGs.
mac-sparkle-appcast release_dir:
    "$({{macos_dir}}/scripts/find_sparkle_tool.sh generate_appcast)" "{{release_dir}}"

# Submit an already-built DMG to Apple notarization and staple the ticket.
mac-notarize dmg:
    @test -f "{{dmg}}" || (echo "❌ DMG not found: {{dmg}}"; exit 1)
    @test -n "${APPLE_ID:-}" || (echo "❌ APPLE_ID not set"; exit 1)
    @test -n "${APPLE_TEAM_ID:-}" || (echo "❌ APPLE_TEAM_ID not set"; exit 1)
    @test -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" || (echo "❌ APPLE_APP_SPECIFIC_PASSWORD not set"; exit 1)
    xcrun notarytool submit "{{dmg}}" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "{{dmg}}"
    spctl -a -t open -vv "{{dmg}}"

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


# ─── native iOS/iPadOS build ─────────────────────────────────────────────

# One-time prerequisites for the native iOS/iPadOS build.
ios-bootstrap:
    @command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
    rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
    @echo "✅ iOS/iPadOS prereqs installed"

# Build the iOS simulator app without signing. Use this for compiler validation.
ios-ci-build:
    @just _ensure-xcodeproj
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{ios_scheme}} \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath {{ios_sim_dd}} \
        CODE_SIGNING_ALLOWED=NO \
        build

# Build the iOS simulator app signed for local launch. Keychain APIs need the
# simulator entitlements emitted by Xcode, so this is separate from CI build.
ios-sim-build:
    @just _ensure-xcodeproj
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{ios_scheme}} \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath {{ios_sim_dd}} \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGN_IDENTITY="-" \
        build

# Build, install, and launch on an iPad simulator. Pass a simulator name
# fragment if you want a specific iPad, e.g. `just run-on-ipad "iPad Pro"`.
run-on-ipad name="":
    @just ios-sim-build
    @app="{{ios_sim_app}}"; \
    bundle="{{ios_bundle}}"; \
    name="{{name}}"; \
    test -d "$app" || (echo "iOS simulator app not found: $app"; exit 1); \
    if [ -n "$name" ]; then \
        udid="$(xcrun simctl list devices available | grep 'iPad' | grep -F "$name" | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
    else \
        udid="$(xcrun simctl list devices available | grep 'iPad' | grep 'Booted' | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
        if [ -z "$udid" ]; then \
            udid="$(xcrun simctl list devices available | grep 'iPad' | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
        fi; \
    fi; \
    test -n "$udid" || (echo "No available iPad simulator found"; xcrun simctl list devices available; exit 1); \
    if ! xcrun simctl list devices | grep "$udid" | grep -q 'Booted'; then \
        xcrun simctl boot "$udid" || true; \
        xcrun simctl bootstatus "$udid" -b; \
    fi; \
    open -a Simulator; \
    xcrun simctl install "$udid" "$app"; \
    xcrun simctl launch "$udid" "$bundle"; \
    echo "Launched midnight-ssh on iPad simulator $udid"

# Build the iOS app for a connected device or archive workflow.
ios-build config="Debug":
    @just _ensure-xcodeproj
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{ios_scheme}} \
        -configuration {{config}} \
        -destination 'generic/platform=iOS' \
        -derivedDataPath /private/tmp/rshell-ios-device-dd \
        build

# Clean only iOS build outputs.
ios-clean:
    rm -rf {{ios_sim_dd}} /private/tmp/rshell-ios-device-dd
    rm -rf target/universal-ios
    rm -rf target/aarch64-apple-ios target/aarch64-apple-ios-sim target/x86_64-apple-ios
    @echo "✅ iOS build artifacts cleaned"


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
    @if [ ! -d {{xcode_proj}} ] || \
        [ {{macos_dir}}/project.yml -nt {{xcode_proj}}/project.pbxproj ] || \
        find {{macos_dir}}/RShellApp {{macos_dir}}/RShellMobile {{macos_dir}}/Sources {{macos_dir}}/Tests -name '*.swift' -newer {{xcode_proj}}/project.pbxproj | grep -q .; then \
        just mac-gen; \
    fi
