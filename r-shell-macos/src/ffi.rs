use crate::bridge::MacOsBridge;

// ---------------------------------------------------------------------------
// Protocol types — shared between Rust and Swift via uniffi-generated bindings.
// These are the wire-format records for every FFI operation.
// ---------------------------------------------------------------------------

/// Parameters for creating an SSH connection.
/// Maps to a uniffi `dictionary` in Swift; generated bindings produce
/// a native Swift struct that callers construct inline.
#[derive(uniffi::Record)]
pub struct FfiConnectConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    /// Password for password-based auth. May be `None` when using key-based auth.
    pub password: Option<String>,
    /// Filesystem path to a private key for key-based auth. May be `None`
    /// when using password auth.
    pub key_path: Option<String>,
    /// Optional passphrase to decrypt the private key.
    pub passphrase: Option<String>,
    /// Optional unique suffix that lets the same `(user, host, port)` triple
    /// be opened more than once (e.g., one terminal tab per session). When
    /// `Some("abc")`, the connection is keyed as `"user@host:port#abc"` in
    /// `pty_sessions`. When `None`, the bare key is used (suitable for the
    /// simple "single connection per host" case).
    pub session_id: Option<String>,
}

/// Universal result struct for FFI operations.
///
/// `success` indicates whether the operation completed. When `success` is
/// `false`, `error` contains a human-readable description of what went wrong.
/// When `success` is `true`, `value` may carry extra payload (e.g. a PTY
/// generation counter as a JSON string).
#[derive(uniffi::Record)]
pub struct FfiResult {
    pub success: bool,
    pub error: Option<String>,
    /// JSON-encoded extra payload (e.g. `{"generation": 3}` for PTY start)
    pub value: Option<String>,
}

/// An event emitted by the Rust core and delivered to the Swift layer via
/// the registered `FfiEventCallback`.
///
/// `ty` identifies the event kind: `"pty_output"`, `"connection_status"`,
/// `"transfer_progress"`, or `"action_complete"`.
///
/// `connection_id` is the connection this event relates to.
///
/// `payload` is a JSON-encoded string with the event-specific data.
#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiEvent {
    pub ty: String,
    pub connection_id: String,
    pub payload: String,
}

// ---------------------------------------------------------------------------
// Callback interface — the Swift side implements this to receive events.
// ---------------------------------------------------------------------------

/// Callback trait that the Swift layer implements to receive asynchronous
/// events from the Rust core. Registered once via `rshell_set_event_callback`.
///
/// `FfiEventCallback` is `Send + Sync` so it can be invoked from any Tokio
/// task spawned by the bridge.
#[uniffi::export(callback_interface)]
pub trait FfiEventCallback: Send + Sync {
    fn on_event(&self, event: FfiEvent);
}

// ---------------------------------------------------------------------------
// Event bus wiring — forwards r-shell-core events to the registered Swift
// callback. Runs inside the bridge's Tokio runtime, so the callback must be
// Send + Sync.
// ---------------------------------------------------------------------------

/// Spawn a background Tokio task on the bridge runtime that drains the
/// core event bus and forwards every event to the registered callback.
/// The task lives until the bridge runtime is dropped (process exit).
fn start_event_listener(callback: Box<dyn FfiEventCallback>) {
    let bridge = MacOsBridge::global();
    let mut rx = r_shell_core::event_bus::subscribe();
    bridge.runtime.spawn(async move {
        use tokio::sync::broadcast::error::RecvError;
        loop {
            match rx.recv().await {
                Ok(core_event) => {
                    use r_shell_core::event_bus::{ConnectionStatus, CoreEvent};
                    let (ty, connection_id, payload) = match core_event {
                        CoreEvent::PtyOutput { connection_id, generation, data } => (
                            "pty_output".into(),
                            connection_id,
                            // `{"generation": N, "bytes": [...]}` so the
                            // consumer can drop stale frames whose
                            // generation no longer matches the active
                            // session. Bare-array payloads are gone.
                            serde_json::json!({
                                "generation": generation,
                                "bytes": data,
                            }).to_string(),
                        ),
                        CoreEvent::ConnectionStatus { connection_id, status } => {
                            let status_str = match status {
                                ConnectionStatus::Connected => "connected",
                                ConnectionStatus::Disconnected => "disconnected",
                                ConnectionStatus::Error { .. } => "error",
                            };
                            (
                                "connection_status".into(),
                                connection_id,
                                format!("{{\"status\":\"{}\"}}", status_str),
                            )
                        }
                        CoreEvent::TransferProgress {
                            connection_id,
                            path,
                            bytes_transferred,
                            total_bytes,
                        } => (
                            "transfer_progress".into(),
                            connection_id,
                            serde_json::json!({
                                "path": path,
                                "bytesTransferred": bytes_transferred,
                                "totalBytes": total_bytes,
                            })
                            .to_string(),
                        ),
                    };
                    let ffi_event = FfiEvent {
                        ty,
                        connection_id,
                        payload,
                    };
                    callback.on_event(ffi_event);
                }
                Err(RecvError::Lagged(n)) => {
                    tracing::warn!("macOS bridge event bus lagged by {} events", n);
                }
                Err(RecvError::Closed) => {
                    tracing::info!("macOS bridge event bus closed, listener exiting");
                    break;
                }
            }
        }
    });
}

// ---------------------------------------------------------------------------
// FFI-exported functions — the native bridge contract.
// ---------------------------------------------------------------------------

/// Initialise the macOS bridge. Must be called once before any other
/// `rshell_*` function. Creates the Tokio runtime and connection manager.
/// Safe to call multiple times — subsequent calls are no-ops.
#[uniffi::export]
pub fn rshell_init() -> bool {
    MacOsBridge::init();
    true
}

/// Register an event callback. The callback receives `FfiEvent` messages
/// for PTY output, connection status changes, and transfer progress.
/// The callback is moved into a background Tokio task and forwarded to
/// the Swift layer. Must be called at least once before any event-producing
/// operations (PTY start, file transfer, etc.).
#[uniffi::export]
pub fn rshell_set_event_callback(callback: Box<dyn FfiEventCallback>) {
    start_event_listener(callback);
}

/// Typed connect-time failures so the Swift side can pattern-match instead
/// of substring-checking the error string. Variants are classified from
/// the underlying `anyhow::Error` produced by `r-shell-core` based on
/// well-known message phrases — uniffi 0.28 doesn't propagate Rust types
/// through `anyhow`, so this is the natural place for the classification.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ConnectError {
    /// Either no auth method was provided, or the request was missing a
    /// required field. The user can't recover by retrying — they need to
    /// fix the profile.
    #[error("invalid configuration: {detail}")]
    ConfigInvalid { detail: String },

    /// SSH key is encrypted and either no passphrase was supplied or the
    /// supplied one was wrong. The Swift side typically prompts and
    /// retries.
    #[error("SSH key needs a passphrase: {detail}")]
    PassphraseRequired { detail: String },

    /// Server rejected the credential — wrong password, key not in
    /// `authorized_keys`, etc. Distinct from `PassphraseRequired` because
    /// the recovery flow differs (re-prompt password vs unlock key).
    #[error("authentication failed: {detail}")]
    AuthFailed { detail: String },

    /// The stored host fingerprint doesn't match the offered one. Caller
    /// must surface the mismatch so the user can decide whether to
    /// re-trust the host (and removes the old TOFU entry).
    #[error("host key verification failed: {detail}")]
    HostKeyMismatch { detail: String },

    /// TCP-level failure: timeout, refused, reset, allow-list block.
    #[error("network error: {detail}")]
    Network { detail: String },

    /// Anything else — unknown error string from r-shell-core. Swift falls
    /// through to a generic alert.
    #[error("{detail}")]
    Other { detail: String },
}

/// Classify an `anyhow::Error` from r-shell-core into a typed `ConnectError`.
/// The match order matters: passphrase matches must happen before the
/// generic "authentication failed" check, since the passphrase-required
/// error message also contains the word "key" but isn't a remote auth
/// rejection.
fn classify_connect_error(e: &anyhow::Error) -> ConnectError {
    let msg = e.to_string();
    let lower = msg.to_lowercase();

    if lower.contains("passphrase") || lower.contains("encrypted") {
        ConnectError::PassphraseRequired { detail: msg }
    } else if lower.contains("authentication failed") {
        ConnectError::AuthFailed { detail: msg }
    } else if lower.contains("host key")
        || lower.contains("fingerprint")
        || lower.contains("verification failed")
    {
        ConnectError::HostKeyMismatch { detail: msg }
    } else if lower.contains("timed out")
        || lower.contains("reset")
        || lower.contains("refused")
        || lower.contains("connection")
    {
        ConnectError::Network { detail: msg }
    } else {
        ConnectError::Other { detail: msg }
    }
}

/// Establish an SSH connection. Returns the canonical connection id
/// (`"user@host:port"` or `"user@host:port#sessionId"`) on success;
/// throws a typed `ConnectError` on failure.
#[uniffi::export]
pub fn rshell_connect(config: FfiConnectConfig) -> Result<String, ConnectError> {
    let bridge = MacOsBridge::global();
    let mut connection_id = format!("{}@{}:{}", config.username, config.host, config.port);
    if let Some(sid) = config.session_id.as_ref() {
        if !sid.is_empty() {
            connection_id.push('#');
            connection_id.push_str(sid);
        }
    }

    let ssh_config = r_shell_core::ssh::SshConfig {
        host: config.host,
        port: config.port,
        username: config.username,
        auth_method: match (config.password, config.key_path) {
            (Some(password), _) => r_shell_core::ssh::AuthMethod::Password { password },
            (None, Some(key_path)) => r_shell_core::ssh::AuthMethod::PublicKey {
                key_path,
                passphrase: config.passphrase,
            },
            (None, None) => {
                return Err(ConnectError::ConfigInvalid {
                    detail: "Either password or key_path is required".into(),
                });
            }
        },
    };

    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();

    bridge
        .runtime
        .block_on(async move { cm.create_connection(conn_id, ssh_config).await })
        .map(|_| connection_id)
        .map_err(|e| classify_connect_error(&e))
}

/// Disconnect an SSH connection and tear down any associated PTY session.
#[uniffi::export]
pub fn rshell_disconnect(connection_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move { cm.close_connection(&connection_id).await })
        .map(|_| FfiResult {
            success: true,
            error: None,
            value: None,
        })
        .unwrap_or_else(|e| FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        })
}

/// Start an interactive PTY session on an already-connected SSH connection.
/// Returns the generation counter in `value` (as a JSON string) so the
/// frontend can pass it back in `rshell_pty_close` to prevent stale closes.
///
/// Spawns a background task that drains the PTY's `output_rx` channel and
/// publishes each chunk as a `CoreEvent::PtyOutput` on the event bus, so the
/// Swift event callback receives terminal output. The macOS app is the only
/// consumer of `output_rx` (Tauri uses `read_pty_burst` in its own process),
/// so there is no contention.
#[uniffi::export]
pub fn rshell_pty_start(connection_id: String, cols: u32, rows: u32) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id_for_start = connection_id.clone();

    let result = bridge
        .runtime
        .block_on(async move { cm.start_pty_connection(&conn_id_for_start, cols, rows).await });

    match result {
        Ok(generation) => {
            spawn_pty_output_forwarder(connection_id.clone(), generation, bridge);
            FfiResult {
                success: true,
                error: None,
                value: Some(serde_json::json!({"generation": generation}).to_string()),
            }
        }
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

/// Drain the active PTY's `output_rx` and publish each chunk on the event
/// bus, tagged with `generation`. Captures the `Arc<PtySession>` once so
/// a subsequent restart of the PTY for the same `connection_id` doesn't
/// redirect this loop to the new session's receiver — when the captured
/// session is cancelled or its channel closes, the loop exits.
///
/// Stamping every published event with `generation` lets the consumer
/// drop frames from an old PTY session that's tearing down: the new
/// session has a higher generation counter, the consumer remembers it,
/// and any straggler events from before the swap are recognisable as
/// stale.
fn spawn_pty_output_forwarder(connection_id: String, generation: u64, bridge: &MacOsBridge) {
    let cm = bridge.connection_manager.clone();
    bridge.runtime.spawn(async move {
        let pty = match cm.get_pty_session(&connection_id).await {
            Some(p) => p,
            None => {
                tracing::warn!("PTY forwarder: no session for {}", connection_id);
                return;
            }
        };
        let cancel = pty.cancel.clone();
        let output_rx = pty.output_rx.clone();
        // Drop our strong handle to PtySession; the captured `output_rx` Arc
        // keeps the receiver alive for as long as we need it.
        drop(pty);

        let tx = match r_shell_core::event_bus::event_sender() {
            Some(t) => t,
            None => {
                tracing::error!("PTY forwarder: event bus unavailable");
                return;
            }
        };

        loop {
            tokio::select! {
                biased;
                _ = cancel.cancelled() => {
                    tracing::debug!("PTY forwarder for {} cancelled", connection_id);
                    break;
                }
                msg = async {
                    let mut rx = output_rx.lock().await;
                    rx.recv().await
                } => {
                    match msg {
                        Some(data) if !data.is_empty() => {
                            // Send may fail if all subscribers dropped — that's
                            // fine, just keep draining so the channel doesn't
                            // back-pressure the SSH reader.
                            let _ = tx.send(r_shell_core::event_bus::CoreEvent::PtyOutput {
                                connection_id: connection_id.clone(),
                                generation,
                                data,
                            });
                        }
                        Some(_) => continue, // empty chunk, ignore
                        None => {
                            tracing::debug!("PTY forwarder for {} channel closed", connection_id);
                            break;
                        }
                    }
                }
            }
        }
    });
}

/// Write data (user input) to a running PTY session.
#[uniffi::export]
pub fn rshell_pty_write(connection_id: String, data: Vec<u8>) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move { cm.write_to_pty(&connection_id, data).await })
        .map(|_| FfiResult {
            success: true,
            error: None,
            value: None,
        })
        .unwrap_or_else(|e| FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        })
}

/// Resize a running PTY session's terminal dimensions.
#[uniffi::export]
pub fn rshell_pty_resize(connection_id: String, cols: u32, rows: u32) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move { cm.resize_pty(&connection_id, cols, rows).await })
        .map(|_| FfiResult {
            success: true,
            error: None,
            value: None,
        })
        .unwrap_or_else(|e| FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        })
}

/// Close a PTY session. The `expected_generation` is the generation counter
/// returned by `rshell_pty_start`; if it doesn't match the current session,
/// the close is ignored (prevents stale-close races from component remounts).
#[uniffi::export]
pub fn rshell_pty_close(connection_id: String, expected_generation: u64) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge
        .runtime
        .block_on(async move {
            cm.close_pty_connection(&connection_id, Some(expected_generation))
                .await
        })
        .map(|_| FfiResult {
            success: true,
            error: None,
            value: None,
        })
        .unwrap_or_else(|e| FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        })
}

/// Execute a remote command on an SSH connection and return the output.
/// Blocks until the command completes or fails.
#[uniffi::export]
pub fn rshell_execute_command(connection_id: String, command: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();
    let result = bridge.runtime.block_on(async move {
        let client = cm.get_connection(&conn_id).await;
        match client {
            Some(c) => {
                let client = c.read().await;
                client.execute_command(&command).await
            }
            None => Err(anyhow::anyhow!("Connection not found: {}", conn_id)),
        }
    });
    match result {
        Ok(output) => FfiResult {
            success: true,
            error: None,
            value: Some(output),
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

// ---------------------------------------------------------------------------
// Keychain FFI — wraps r-shell-core keychain for Swift access.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum)]
pub enum FfiCredentialKind {
    SshPassword,
    SshKeyPassphrase,
    SftpPassword,
    SftpKeyPassphrase,
    FtpPassword,
}

impl From<FfiCredentialKind> for r_shell_core::keychain::CredentialKind {
    fn from(k: FfiCredentialKind) -> Self {
        match k {
            FfiCredentialKind::SshPassword => Self::SshPassword,
            FfiCredentialKind::SshKeyPassphrase => Self::SshKeyPassphrase,
            FfiCredentialKind::SftpPassword => Self::SftpPassword,
            FfiCredentialKind::SftpKeyPassphrase => Self::SftpKeyPassphrase,
            FfiCredentialKind::FtpPassword => Self::FtpPassword,
        }
    }
}

#[uniffi::export]
pub fn rshell_keychain_is_supported() -> bool {
    r_shell_core::keychain::is_supported()
}

#[uniffi::export]
pub fn rshell_keychain_save(kind: FfiCredentialKind, account: String, secret: String) -> FfiResult {
    let core_kind: r_shell_core::keychain::CredentialKind = kind.into();
    match r_shell_core::keychain::save_password(core_kind, &account, &secret) {
        Ok(_) => FfiResult { success: true, error: None, value: None },
        Err(e) => FfiResult { success: false, error: Some(e.to_string()), value: None },
    }
}

#[uniffi::export]
pub fn rshell_keychain_load(kind: FfiCredentialKind, account: String) -> FfiResult {
    let core_kind: r_shell_core::keychain::CredentialKind = kind.into();
    match r_shell_core::keychain::load_password(core_kind, &account) {
        Ok(Some(secret)) => FfiResult {
            success: true,
            error: None,
            value: Some(secret),
        },
        Ok(None) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult { success: false, error: Some(e.to_string()), value: None },
    }
}

#[uniffi::export]
pub fn rshell_keychain_delete(kind: FfiCredentialKind, account: String) -> FfiResult {
    let core_kind: r_shell_core::keychain::CredentialKind = kind.into();
    match r_shell_core::keychain::delete_password(core_kind, &account) {
        Ok(_) => FfiResult { success: true, error: None, value: None },
        Err(e) => FfiResult { success: false, error: Some(e.to_string()), value: None },
    }
}

#[uniffi::export]
pub fn rshell_keychain_list(kind: FfiCredentialKind) -> Vec<String> {
    let core_kind: r_shell_core::keychain::CredentialKind = kind.into();
    r_shell_core::keychain::list_accounts(core_kind).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_succeeds() {
        assert!(rshell_init());
    }

    #[test]
    fn connect_without_auth_fails_descriptive() {
        rshell_init();
        let result = rshell_connect(FfiConnectConfig {
            host: "nonexistent.example.com".into(),
            port: 22,
            username: "test".into(),
            password: None,
            key_path: None,
            passphrase: None,
            session_id: None,
        });
        match result {
            Err(ConnectError::ConfigInvalid { detail }) => {
                assert!(detail.contains("password or key_path"));
            }
            other => panic!("expected ConfigInvalid, got {:?}", other),
        }
    }

    #[test]
    fn disconnect_unknown_id_is_ok() {
        rshell_init();
        let result = rshell_disconnect("does-not-exist".into());
        assert!(result.success);
    }
}
