//! macOS Keychain integration for SSH / SFTP / FTP credentials.
//!
//! The frontend stores passwords and key passphrases in the system Keychain
//! instead of re-sending them on every connect. Each credential is keyed by a
//! `(service, account)` pair where `service` is derived from [`CredentialKind`]
//! and `account` is an opaque string chosen by the caller (typically
//! `"<username>@<host>:<port>"`).
//!
//! On platforms without a Keychain:
//! - `save_password` / `delete_password` return a "not supported" error
//! - `load_password` returns `Ok(None)` so a "no saved credential" flow is
//!   indistinguishable from "no Keychain exists", letting the UI fall back to
//!   a password prompt gracefully.
//!
//! Secrets are held as `String` at the boundary and converted to `&[u8]` for
//! the Keychain API. They must never be logged — callers and this module use
//! `tracing` only to report the non-sensitive `(service, account)` pair.

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// Kinds of credential we persist. Serialised in snake_case on the wire so the
/// frontend can emit e.g. `{"kind": "ssh_password"}`.
///
/// Each variant maps to a fixed Keychain service string prefixed with
/// `com.r-shell.` so the entries are easy to identify in Keychain Access.app
/// and distinct from credentials stored by other applications.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CredentialKind {
    SshPassword,
    SshKeyPassphrase,
    SftpPassword,
    SftpKeyPassphrase,
    FtpPassword,
}

impl CredentialKind {
    /// The Keychain `kSecAttrService` string associated with this kind.
    pub fn service(self) -> &'static str {
        match self {
            CredentialKind::SshPassword => "com.r-shell.ssh.password",
            CredentialKind::SshKeyPassphrase => "com.r-shell.ssh.passphrase",
            CredentialKind::SftpPassword => "com.r-shell.sftp.password",
            CredentialKind::SftpKeyPassphrase => "com.r-shell.sftp.passphrase",
            CredentialKind::FtpPassword => "com.r-shell.ftp.password",
        }
    }
}

/// Whether this build can actually read / write the OS keychain.
/// The frontend uses this to hide "Save to Keychain" UI on unsupported
/// platforms instead of letting the save call error at runtime.
pub fn is_supported() -> bool {
    cfg!(target_os = "macos")
}

// =============================================================================
// macOS implementation — real Keychain access via `security-framework`.
// =============================================================================
#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use security_framework::passwords::{
        delete_generic_password, get_generic_password, set_generic_password,
    };
    use security_framework_sys::base::errSecItemNotFound;

    pub fn save_password(kind: CredentialKind, account: &str, secret: &str) -> Result<()> {
        set_generic_password(kind.service(), account, secret.as_bytes()).map_err(|e| {
            anyhow::anyhow!(
                "keychain save failed for {}/{}: {}",
                kind.service(),
                account,
                e
            )
        })
    }

    pub fn load_password(kind: CredentialKind, account: &str) -> Result<Option<String>> {
        match get_generic_password(kind.service(), account) {
            Ok(bytes) => {
                let s = String::from_utf8(bytes).map_err(|_| {
                    anyhow::anyhow!(
                        "keychain item {}/{} is not valid UTF-8",
                        kind.service(),
                        account
                    )
                })?;
                Ok(Some(s))
            }
            Err(e) if e.code() == errSecItemNotFound => Ok(None),
            Err(e) => Err(anyhow::anyhow!(
                "keychain load failed for {}/{}: {}",
                kind.service(),
                account,
                e
            )),
        }
    }

    pub fn delete_password(kind: CredentialKind, account: &str) -> Result<()> {
        // Idempotent: deleting a nonexistent item is not an error.
        match delete_generic_password(kind.service(), account) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == errSecItemNotFound => Ok(()),
            Err(e) => Err(anyhow::anyhow!(
                "keychain delete failed for {}/{}: {}",
                kind.service(),
                account,
                e
            )),
        }
    }
}

// =============================================================================
// Non-macOS stubs
// =============================================================================
#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;

    pub fn save_password(_kind: CredentialKind, _account: &str, _secret: &str) -> Result<()> {
        Err(anyhow::anyhow!(
            "Keychain integration is only supported on macOS"
        ))
    }

    pub fn load_password(_kind: CredentialKind, _account: &str) -> Result<Option<String>> {
        // Report "no saved credential" so the UI can gracefully fall back to
        // prompting for the password rather than surfacing an error.
        Ok(None)
    }

    pub fn delete_password(_kind: CredentialKind, _account: &str) -> Result<()> {
        Err(anyhow::anyhow!(
            "Keychain integration is only supported on macOS"
        ))
    }
}

pub fn save_password(kind: CredentialKind, account: &str, secret: &str) -> Result<()> {
    tracing::info!(
        "keychain save: service={}, account={}",
        kind.service(),
        account
    );
    platform::save_password(kind, account, secret)
}

pub fn load_password(kind: CredentialKind, account: &str) -> Result<Option<String>> {
    let result = platform::load_password(kind, account);
    tracing::debug!(
        "keychain load: service={}, account={}, found={}",
        kind.service(),
        account,
        matches!(&result, Ok(Some(_)))
    );
    result
}

pub fn delete_password(kind: CredentialKind, account: &str) -> Result<()> {
    tracing::info!(
        "keychain delete: service={}, account={}",
        kind.service(),
        account
    );
    platform::delete_password(kind, account)
}

// =============================================================================
// Tests
// =============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_strings_are_stable_and_unique() {
        let kinds = [
            CredentialKind::SshPassword,
            CredentialKind::SshKeyPassphrase,
            CredentialKind::SftpPassword,
            CredentialKind::SftpKeyPassphrase,
            CredentialKind::FtpPassword,
        ];
        // All prefixed with com.r-shell. so they're easy to find in Keychain
        // Access.app and grouped apart from other applications.
        for k in kinds {
            assert!(
                k.service().starts_with("com.r-shell."),
                "service {:?} should be namespaced",
                k
            );
        }
        // And every kind maps to a distinct service.
        let set: std::collections::HashSet<&str> = kinds.iter().map(|k| k.service()).collect();
        assert_eq!(set.len(), kinds.len(), "service strings must be unique");
    }

    #[test]
    fn credential_kind_serializes_snake_case() {
        let json = serde_json::to_string(&CredentialKind::SshKeyPassphrase).unwrap();
        assert_eq!(json, "\"ssh_key_passphrase\"");
    }

    #[test]
    fn credential_kind_deserializes_snake_case() {
        let kind: CredentialKind = serde_json::from_str("\"ftp_password\"").unwrap();
        assert_eq!(kind, CredentialKind::FtpPassword);
    }

    /// Round-trip against the real Keychain. Ignored by default so `cargo test`
    /// on a developer machine doesn't prompt for Keychain access or leave
    /// residue. Run with `cargo test -- --ignored` to exercise on macOS.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore]
    fn save_load_delete_round_trip_on_real_keychain() {
        let kind = CredentialKind::SshPassword;
        let account = format!("r-shell-test-{}@localhost:22", std::process::id());
        let secret = "round-trip-secret-value";

        // Nothing there initially.
        let before = load_password(kind, &account).expect("load");
        assert!(before.is_none(), "pre-existing keychain entry?");

        save_password(kind, &account, secret).expect("save");
        let loaded = load_password(kind, &account).expect("load").expect("some");
        assert_eq!(loaded, secret);

        // Overwrite is supported (set_generic_password updates in place).
        save_password(kind, &account, "different-value").expect("overwrite");
        let loaded2 = load_password(kind, &account).expect("reload").expect("some");
        assert_eq!(loaded2, "different-value");

        delete_password(kind, &account).expect("delete");
        let after = load_password(kind, &account).expect("load after delete");
        assert!(after.is_none(), "entry should be gone after delete");

        // Delete is idempotent.
        delete_password(kind, &account).expect("idempotent delete");
    }
}
