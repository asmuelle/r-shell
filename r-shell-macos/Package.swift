// swift-tools-version: 5.9
// r-shell-macos SPM package — wraps the Rust static lib for the native macOS app.
//
// ## Prerequisites
//
//   brew install xcodegen
//
// ## Setup (one-time)
//
//   1. Generate Xcode project:
//        cd r-shell-macos && xcodegen generate
//
//   2. Open R-Shell.xcodeproj in Xcode
//
//   3. Select the RShellApp scheme, choose and macOS target, run
//
// The `build_cargo.sh` script runs automatically as a build phase and
// produces a universal (arm64 + x86_64) static library at
// `target/universal/release/libr_shell_macos.a`.
//
// ## Generating Swift bindings
//
// After every FFI change:
//
//   cargo build -p r-shell-macos --release --target aarch64-apple-darwin
//   uniffi-bindgen generate \
//     target/aarch64-apple-darwin/release/libr_shell_macos.dylib \
//     --language swift \
//     --out-dir bindings
//
// Then add the generated `r_shell_macosFFI.h` and `r_shell_macosFFI.modulemap`
// to the Xcode project's "Swift Compiler — General" > "Import Paths".

import PackageDescription

let package = Package(
    name: "r-shell-macos",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "RShellMacOS",
            targets: ["RShellMacOS"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RShellMacOS",
            path: "Sources/RShellMacOS",
            linkerSettings: [
                .linkedLibrary("r_shell_macos"),
            ]
        ),
        .testTarget(
            name: "RShellMacOSTests",
            dependencies: ["RShellMacOS"],
            path: "Tests/RShellMacOSTests"
        ),
    ]
)
