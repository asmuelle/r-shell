//! Tauri command surface, organised by domain.
//!
//! Each submodule owns the commands, request/response types, and helpers for a
//! single protocol or subsystem. Shared primitives that multiple submodules
//! need (envelope types, input-normalisation helpers) live in this file.
//!
//! Re-exports at the bottom keep `lib.rs`'s `tauri::generate_handler!` macro
//! working with flat paths like `commands::ssh_connect` after the split.

use serde::{Deserialize, Serialize};

/// Enum form of the `auth_method` field on `ConnectRequest` / `SftpConnectRequest`.
/// Serialised lowercase (`"password"` / `"publickey"`) to preserve the wire
/// format the frontend already sends.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AuthMethodTag {
    Password,
    PublicKey,
}

pub mod desktop;
pub mod ftp;
pub mod gpu;
pub mod local_fs;
pub mod logs;
pub mod network;
pub mod processes;
pub mod remote_fs;
pub mod sftp;
pub mod ssh;
pub mod ssh_fs;
pub mod system;
pub mod websocket;

// ============================================================================
// Shared response envelope — used by commands across domains.
// ============================================================================

#[derive(Debug, Serialize)]
pub struct CommandResponse {
    pub success: bool,
    pub output: Option<String>,
    pub error: Option<String>,
}

// ============================================================================
// Request-field normalisation. These live at crate-root visibility so that
// each domain submodule can reuse them without duplicating trim/empty checks.
// ============================================================================

pub(crate) fn normalize_required_field(
    value: String,
    field_name: &str,
) -> Result<String, String> {
    let normalized = value.trim().to_string();
    if normalized.is_empty() {
        return Err(format!("{field_name} required"));
    }
    Ok(normalized)
}

pub(crate) fn normalize_optional_trimmed(value: Option<String>) -> Option<String> {
    value
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

pub(crate) fn normalize_optional_non_blank(value: Option<String>) -> Option<String> {
    value.filter(|s| !s.trim().is_empty())
}

// ============================================================================
// File transfer request/response — shared between deprecated `sftp_*` commands
// in `ssh_fs` and the unified commands in `remote_fs`.
// ============================================================================

#[derive(Debug, Serialize, Deserialize)]
pub struct FileTransferRequest {
    pub connection_id: String,
    pub local_path: String,
    pub remote_path: String,
    pub data: Option<Vec<u8>>,
}

#[derive(Debug, Serialize)]
pub struct FileTransferResponse {
    pub success: bool,
    pub bytes_transferred: Option<u64>,
    pub data: Option<Vec<u8>>,
    pub error: Option<String>,
}

// ============================================================================
// Flat re-exports — preserves `commands::<name>` paths used by lib.rs
// ============================================================================

pub use desktop::*;
pub use ftp::*;
pub use gpu::*;
pub use local_fs::*;
pub use logs::*;
pub use network::*;
pub use processes::*;
pub use remote_fs::*;
pub use sftp::*;
pub use ssh::*;
pub use ssh_fs::*;
pub use system::*;
pub use websocket::*;

// ============================================================================
// Tests for the normalisation helpers.
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_required_field_trims_whitespace() {
        let value = normalize_required_field("  root  ".to_string(), "Username").unwrap();
        assert_eq!(value, "root");
    }

    #[test]
    fn normalize_required_field_rejects_blank_values() {
        let error = normalize_required_field("   ".to_string(), "Host").unwrap_err();
        assert_eq!(error, "Host required");
    }

    #[test]
    fn normalize_optional_trimmed_strips_surrounding_whitespace() {
        let value = normalize_optional_trimmed(Some("  ~/.ssh/id_rsa  ".to_string())).unwrap();
        assert_eq!(value, "~/.ssh/id_rsa");
    }

    #[test]
    fn normalize_optional_non_blank_turns_whitespace_only_into_none() {
        assert_eq!(normalize_optional_non_blank(Some("   ".to_string())), None);
        assert_eq!(
            normalize_optional_non_blank(Some(" keep-me ".to_string())),
            Some(" keep-me ".to_string())
        );
    }
}
