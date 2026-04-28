//! r-shell-macos: Native macOS app Rust side.
//!
//! This crate provides the FFI bridge between the Rust domain layer
//! (`r-shell-core`) and the native macOS Swift frontend.
//!
//! The bridge is defined via `uniffi` proc-macros in the `ffi` module.
//! Swift bindings are generated from the compiled library by running:
//!   uniffi-bindgen generate src/lib.rs --language swift --out-dir ../bindings

mod bridge;
mod ffi;

uniffi::setup_scaffolding!();
