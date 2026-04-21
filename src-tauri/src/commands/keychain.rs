//! Tauri commands exposing the macOS Keychain for SSH / SFTP / FTP credentials.
//!
//! The frontend flow is:
//! 1. `keychain_available()` — call once at startup. When false, hide any
//!    "Save to Keychain" UI and fall back to plain-password prompts.
//! 2. On connect form load: `keychain_load(kind, account)` to prefill the
//!    password if a saved entry exists.
//! 3. After a successful connect with the "save" checkbox: `keychain_save(
//!    kind, account, secret)`.
//! 4. On user-initiated credential removal: `keychain_delete(kind, account)`.
//!
//! `account` is an opaque string chosen by the frontend; the convention is
//! `"<username>@<host>:<port>"` so the same credential is reused across
//! reconnects to the same endpoint.

use crate::keychain::{self, CredentialKind};

#[tauri::command]
pub async fn keychain_available() -> Result<bool, String> {
    Ok(keychain::is_supported())
}

#[tauri::command]
pub async fn keychain_save(
    kind: CredentialKind,
    account: String,
    secret: String,
) -> Result<(), String> {
    keychain::save_password(kind, &account, &secret).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn keychain_load(
    kind: CredentialKind,
    account: String,
) -> Result<Option<String>, String> {
    keychain::load_password(kind, &account).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn keychain_delete(kind: CredentialKind, account: String) -> Result<(), String> {
    keychain::delete_password(kind, &account).map_err(|e| e.to_string())
}

/// List all accounts stored under the given credential kind. Returns an empty
/// array — never an error — when no entries exist or the platform has no
/// keychain, so the UI can render a "nothing saved" state unconditionally.
#[tauri::command]
pub async fn keychain_list(kind: CredentialKind) -> Result<Vec<String>, String> {
    keychain::list_accounts(kind).map_err(|e| e.to_string())
}
