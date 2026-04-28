// RShellMacOS — pure-Swift models shared by the macOS app target.
//
// ## Architecture
//
// The Rust crate is built by Cargo as a universal static library and
// linked into the **app** target (RShellApp). The uniffi-generated Swift
// bindings live at `r-shell-macos/bindings/r_shell_macos.swift` and are
// also compiled into the app target — frameworks cannot link the Rust
// static lib directly, so the FFI surface lives where the symbols can
// actually be resolved.
//
// This framework owns only the pure-Swift models (`ConnectionProfile`,
// `WorkspaceLayout`, `LayoutConstants`, …) shared between app sources
// and tests.
//
// ## Bridge lifecycle (in the app target)
//
//   AppDelegate
//     └─ applicationDidFinishLaunching
//          └─ BridgeManager.shared.initialize()
//               ├─ rshell_init()                — create Tokio runtime + ConnectionManager
//               └─ rshell_set_event_callback()  — register event bus listener

import Foundation

/// Logger subsystem identifier used across the app.
public let RShellLogSubsystem = "com.r-shell"
