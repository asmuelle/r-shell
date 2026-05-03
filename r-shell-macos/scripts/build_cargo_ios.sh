#!/bin/bash
# Xcode build phase script: builds the Rust bridge for iOS/iPadOS.
#
# The macOS app links a universal Darwin static library from
# target/universal/release. iOS needs a different archive because simulator and
# device targets use iOS triples. This script builds only the architecture(s)
# Xcode asks for, then writes a lipo archive to target/universal-ios/release so
# project.yml can use one stable LIBRARY_SEARCH_PATHS entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_PROJECT_DIR="${RUST_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
RUST_TARGET_DIR="${RUST_TARGET_DIR:-${RUST_PROJECT_DIR}/target}"
LIB_NAME="libr_shell_macos.a"

case "${CONFIGURATION:-Debug}" in
    Release)
        CARGO_FLAG="--release"
        CARGO_PROFILE="release"
        ;;
    *)
        CARGO_FLAG=""
        CARGO_PROFILE="debug"
        ;;
esac

platform="${PLATFORM_NAME:-iphonesimulator}"
archs="${ARCHS:-arm64}"

rust_target_for_arch() {
    local arch="$1"
    case "$platform:$arch" in
        iphoneos:arm64) echo "aarch64-apple-ios" ;;
        iphonesimulator:arm64) echo "aarch64-apple-ios-sim" ;;
        iphonesimulator:x86_64) echo "x86_64-apple-ios" ;;
        *)
            echo "unsupported iOS Rust target for PLATFORM_NAME=$platform ARCH=$arch" >&2
            return 1
            ;;
    esac
}

ensure_rust_target() {
    local triple="$1"
    if ! rustup target list --installed | grep -qx "$triple"; then
        echo "Missing Rust target: $triple"
        echo "   Install it with: rustup target add $triple"
        exit 1
    fi
}

echo "Building r-shell-macos Rust library for iOS"
echo "   Project:  $RUST_PROJECT_DIR"
echo "   Platform: $platform"
echo "   Archs:    $archs"
echo "   Config:   ${CONFIGURATION:-Debug}"

cd "$RUST_PROJECT_DIR"

libs=()
for arch in $archs; do
    triple="$(rust_target_for_arch "$arch")"
    ensure_rust_target "$triple"
    cargo build -p r-shell-macos $CARGO_FLAG --target "$triple"

    lib="$RUST_TARGET_DIR/$triple/$CARGO_PROFILE/$LIB_NAME"
    if [ ! -f "$lib" ]; then
        echo "Missing static lib: $lib"
        exit 1
    fi
    libs+=("$lib")
done

UNIVERSAL_DIR="$RUST_TARGET_DIR/universal-ios/release"
mkdir -p "$UNIVERSAL_DIR"
UNIVERSAL_LIB="$UNIVERSAL_DIR/$LIB_NAME"

if [ "${#libs[@]}" -eq 1 ]; then
    cp -f "${libs[0]}" "$UNIVERSAL_LIB"
else
    lipo -create "${libs[@]}" -output "$UNIVERSAL_LIB"
fi

echo "iOS static library: $UNIVERSAL_LIB"
if command -v lipo >/dev/null 2>&1; then
    echo "   Archs: $(lipo -info "$UNIVERSAL_LIB")"
fi

# Keep Swift bindings fresh using a host macOS dylib. UniFFI's Swift file and C
# header are platform-neutral for this bridge; only the linked static library is
# platform-specific.
BINDINGS_DIR="$SCRIPT_DIR/../bindings"
BINDINGS_SWIFT="$BINDINGS_DIR/r_shell_macos.swift"
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    arm64) HOST_TARGET="aarch64-apple-darwin" ;;
    x86_64) HOST_TARGET="x86_64-apple-darwin" ;;
    *) echo "Unknown host architecture: $HOST_ARCH"; exit 1 ;;
esac
HOST_DYLIB="$RUST_TARGET_DIR/$HOST_TARGET/$CARGO_PROFILE/libr_shell_macos.dylib"

needs_regen=0
for src in "$RUST_PROJECT_DIR/r-shell-macos/src/ffi.rs" \
           "$RUST_PROJECT_DIR/r-shell-macos/src/lib.rs"; do
    if [ ! -f "$BINDINGS_SWIFT" ] || [ "$src" -nt "$BINDINGS_SWIFT" ]; then
        needs_regen=1
        break
    fi
done

if [ "$needs_regen" -eq 1 ]; then
    ensure_rust_target "$HOST_TARGET"
    cargo build -p r-shell-macos $CARGO_FLAG --target "$HOST_TARGET"

    UNIFFI_BIN="$RUST_TARGET_DIR/release/uniffi-bindgen"
    if [ ! -x "$UNIFFI_BIN" ]; then
        cargo build -p r-shell-macos --release --bin uniffi-bindgen
    fi

    "$UNIFFI_BIN" generate \
        --library "$HOST_DYLIB" \
        --language swift \
        --out-dir "$BINDINGS_DIR"

    if [ -f "$BINDINGS_DIR/r_shell_macosFFI.modulemap" ]; then
        mv -f "$BINDINGS_DIR/r_shell_macosFFI.modulemap" "$BINDINGS_DIR/module.modulemap"
    fi
    echo "Swift bindings regenerated"
else
    echo "Swift bindings up to date (skipping regen)"
fi
