#!/usr/bin/env bash
# Single source of truth for "what green means" in this repo.
#
# Runs the same gates as GitLab CI:
#   fmt-check, file-length QA, architecture QA, clippy, cargo-deny,
#   cargo check (native + wasm target), cargo test, WASM build + frontend smoke.
#
# Opt-out env flags (default off so the default run matches CI exactly):
#   QA_SKIP_WASM=1    — skip the WASM build + frontend smoke step
#   QA_SKIP_TESTS=1   — skip the test step entirely
#   QA_SKIP_DENY=1    — skip `cargo deny`
#
# Opt-in env flags:
#   QA_USE_NEXTEST=1  — replace `cargo test` with `cargo nextest run`
#                       (workspace tests) + `cargo test --doc` (doctests,
#                       nextest does not run them). Requires cargo-nextest.
#
# The Stop hook in .claude/settings.json sets QA_SKIP_WASM=1 and
# QA_USE_NEXTEST=1 for acceptable turnaround during agent sessions. CI and
# `make qa-local` run the default cargo test path unchanged.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

export SQLX_OFFLINE="${SQLX_OFFLINE:-true}"
# Repo-local cargo home so cargo-deny / wasm-bindgen installs survive across
# runs. Previously we used $TMPDIR which macOS wipes periodically.
export CARGO_HOME="${CARGO_HOME:-$ROOT_DIR/.cache/cargo-home}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/target}"
export PATH="$CARGO_HOME/bin:$PATH"
export CARGO_DENY_VERSION="${CARGO_DENY_VERSION:-0.19.1}"
export WASM_BINDGEN_VERSION="${WASM_BINDGEN_VERSION:-0.2.114}"
export FILE_LENGTH_MAX_LINES="${FILE_LENGTH_MAX_LINES:-600}"

QA_SKIP_WASM="${QA_SKIP_WASM:-0}"
QA_SKIP_TESTS="${QA_SKIP_TESTS:-0}"
QA_SKIP_DENY="${QA_SKIP_DENY:-0}"
QA_USE_NEXTEST="${QA_USE_NEXTEST:-0}"

TIMINGS=()

log_step() {
    printf '\n==> %s\n' "$1"
}

timed_step() {
    local label="$1"
    shift
    local start end status=0
    log_step "$label"
    start=$(date +%s)
    # `|| status=$?` keeps set -e from exiting so we can record the timing
    # and emit a summary before propagating the failure.
    "$@" || status=$?
    end=$(date +%s)
    local elapsed=$((end - start))
    TIMINGS+=("$(printf '%-24s %4ds' "$label" "$elapsed")")
    if [ "$status" -ne 0 ]; then
        printf '\nFailed at step: %s (exit %d)\n' "$label" "$status" >&2
        printf 'Timings so far:\n' >&2
        for line in "${TIMINGS[@]}"; do
            printf '  %s\n' "$line" >&2
        done
        exit "$status"
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

ensure_cargo_deny() {
    local bin="$CARGO_HOME/bin/cargo-deny"
    if ! [ -x "$bin" ] || ! "$bin" --version | grep -q "$CARGO_DENY_VERSION"; then
        log_step "Installing cargo-deny $CARGO_DENY_VERSION"
        cargo install cargo-deny \
            --version "$CARGO_DENY_VERSION" \
            --locked --root "$CARGO_HOME" --force
    fi
}

ensure_wasm_bindgen() {
    local bin="$CARGO_HOME/bin/wasm-bindgen"
    if ! [ -x "$bin" ] || ! "$bin" --version | grep -q "$WASM_BINDGEN_VERSION"; then
        log_step "Installing wasm-bindgen-cli $WASM_BINDGEN_VERSION"
        cargo install wasm-bindgen-cli \
            --version "$WASM_BINDGEN_VERSION" \
            --locked --root "$CARGO_HOME" --force
    fi
}

require_command cargo
require_command rustup
require_command python3
require_command node
require_command git

mkdir -p "$CARGO_HOME" "$CARGO_TARGET_DIR"

log_step "Ensuring Rust components"
rustup component add rustfmt clippy
if [ "$QA_SKIP_WASM" != "1" ]; then
    rustup target add wasm32-unknown-unknown
fi

if [ "$QA_SKIP_DENY" != "1" ]; then
    ensure_cargo_deny
fi
if [ "$QA_SKIP_WASM" != "1" ]; then
    ensure_wasm_bindgen
fi

# This repo is a single Tauri crate under src-tauri/, not a workspace.
# All cargo commands must point at that manifest. Mirrors CI's
# `working-directory: src-tauri` from .github/workflows/test.yml.
MANIFEST_PATH="$ROOT_DIR/src-tauri/Cargo.toml"

cargo_fmt_check() {
    cargo fmt --manifest-path "$MANIFEST_PATH" --check
}
timed_step "rustfmt" cargo_fmt_check

structure_qa() {
    python3 scripts/qa/check_file_lengths.py \
        --max-lines "$FILE_LENGTH_MAX_LINES" \
        --baseline scripts/qa/file_length_baseline.json
    python3 scripts/qa/check_architecture.py \
        --rules scripts/qa/architecture_rules.toml
}
timed_step "structure_qa" structure_qa

cargo_clippy() {
    cargo clippy --manifest-path "$MANIFEST_PATH" \
        --all-targets --all-features -- -D warnings
}
timed_step "clippy" cargo_clippy

if [ "$QA_SKIP_DENY" != "1" ]; then
    timed_step "cargo_deny" cargo deny --manifest-path "$MANIFEST_PATH" \
        check -W notice -W unmaintained
fi

cargo_check_all() {
    env RUSTFLAGS=-Dwarnings cargo check \
        --manifest-path "$MANIFEST_PATH" \
        --all-targets --all-features --locked
}
timed_step "cargo_check" cargo_check_all

run_nextest() {
    cargo nextest run --manifest-path "$MANIFEST_PATH" \
        --all-features --locked
}
run_doctests() {
    cargo test --doc --manifest-path "$MANIFEST_PATH" \
        --all-features --locked
}

if [ "$QA_SKIP_TESTS" != "1" ]; then
    if [ "$QA_USE_NEXTEST" = "1" ]; then
        if ! command -v cargo-nextest >/dev/null 2>&1; then
            printf 'QA_USE_NEXTEST=1 but cargo-nextest is not installed.\n' >&2
            printf 'Install: brew install cargo-nextest  OR  cargo binstall cargo-nextest\n' >&2
            exit 1
        fi
        # nextest ignores doctests by design, so we run them separately.
        timed_step "cargo_nextest" run_nextest
        timed_step "cargo_doctest" run_doctests
    else
        timed_step "cargo_test" cargo test \
            --manifest-path "$MANIFEST_PATH" --all-features --locked
    fi
fi

if [ "$QA_SKIP_WASM" != "1" ]; then
    frontend_qa() {
        test -f static/index.html
        test -f static/app.js
        test -f static/style.css
        node --check static/app.js
        rm -rf -- static/wasm
        mkdir -p static/wasm
        cargo build --release -p krust_model_core \
            --target wasm32-unknown-unknown --features wasm --locked
        "$CARGO_HOME/bin/wasm-bindgen" \
            target/wasm32-unknown-unknown/release/krust_model_core.wasm \
            --target web \
            --out-dir static/wasm \
            --no-typescript
    }
    timed_step "frontend_qa" frontend_qa
fi

log_step "QA stage passed"
printf '\nTimings:\n'
for line in "${TIMINGS[@]}"; do
    printf '  %s\n' "$line"
done
