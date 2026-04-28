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
        .map(|_| {
            // Surface the new state so the UI can light up the
            // connected indicator. Status events are best-effort —
            // a future network blip won't be detected unless the SSH
            // layer surfaces it (TODO sprint 10).
            if let Some(tx) = r_shell_core::event_bus::event_sender() {
                let _ = tx.send(r_shell_core::event_bus::CoreEvent::ConnectionStatus {
                    connection_id: connection_id.clone(),
                    status: r_shell_core::event_bus::ConnectionStatus::Connected,
                });
            }
            connection_id
        })
        .map_err(|e| classify_connect_error(&e))
}

/// Disconnect an SSH connection and tear down any associated PTY session.
#[uniffi::export]
pub fn rshell_disconnect(connection_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id_for_close = connection_id.clone();
    let result = bridge
        .runtime
        .block_on(async move { cm.close_connection(&conn_id_for_close).await });

    // Always publish disconnected — close_connection is idempotent on the
    // r-shell-core side, so even an error path here means the session is
    // effectively gone. UI status reflects observable state.
    if let Some(tx) = r_shell_core::event_bus::event_sender() {
        let _ = tx.send(r_shell_core::event_bus::CoreEvent::ConnectionStatus {
            connection_id,
            status: r_shell_core::event_bus::ConnectionStatus::Disconnected,
        });
    }

    result
        .map(|_| FfiResult { success: true, error: None, value: None })
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

        // The PTY for this connection is gone. This covers both clean
        // teardown (close_pty_connection cancels the token) and dirty
        // disconnects (network drop, server kill — `output_rx.recv()`
        // returns None when the SSH reader task exits). The Swift side
        // observes `connection_status: disconnected` and lights up the
        // reconnect affordance. Idempotent vs. the explicit publish in
        // rshell_disconnect — TerminalTabsStore.setStatus dedupes.
        let _ = tx.send(r_shell_core::event_bus::CoreEvent::ConnectionStatus {
            connection_id: connection_id.clone(),
            status: r_shell_core::event_bus::ConnectionStatus::Disconnected,
        });
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
// SFTP — list_dir for the file browser MVP. Upload / download / mkdir /
// delete / rename land in the next slice.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Copy)]
pub enum FfiFileKind {
    File,
    Directory,
    Symlink,
}

#[derive(uniffi::Record)]
pub struct FfiFileEntry {
    pub name: String,
    pub size: u64,
    /// Pre-formatted timestamp string from r-shell-core. `None` when
    /// the SFTP server doesn't supply mtime.
    pub modified: Option<String>,
    /// Pre-formatted POSIX permission string (e.g. `rwxr-xr-x`).
    pub permissions: Option<String>,
    pub kind: FfiFileKind,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SftpError {
    #[error("not connected: {connection_id}")]
    NotConnected { connection_id: String },
    /// User-initiated cancellation via `rshell_sftp_cancel`. Distinct
    /// from `Other` so the UI can mark the transfer cancelled rather
    /// than failed and skip the error toast.
    #[error("cancelled")]
    Cancelled,
    #[error("{detail}")]
    Other { detail: String },
}

/// Per-transfer cancellation registry. A transfer registers its token
/// keyed by the Swift-side UUID; `rshell_sftp_cancel` looks the entry
/// up and triggers it. The download/upload loop checks the token on
/// every chunk.
///
/// `OnceLock<Mutex<...>>` rather than RwLock because writes (register
/// / deregister / cancel) are short and infrequent — no readers to
/// optimise for.
static TRANSFER_CANCELS: std::sync::OnceLock<
    std::sync::Mutex<std::collections::HashMap<String, tokio_util::sync::CancellationToken>>,
> = std::sync::OnceLock::new();

fn transfer_registry()
-> &'static std::sync::Mutex<std::collections::HashMap<String, tokio_util::sync::CancellationToken>>
{
    TRANSFER_CANCELS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// Register a fresh `CancellationToken` for `transfer_id` and return
/// it. The matching `unregister_transfer` call removes the entry on
/// completion or failure so `rshell_sftp_cancel` can't leak past a
/// transfer's lifetime.
fn register_transfer(transfer_id: &str) -> tokio_util::sync::CancellationToken {
    let token = tokio_util::sync::CancellationToken::new();
    transfer_registry()
        .lock()
        .unwrap()
        .insert(transfer_id.to_string(), token.clone());
    token
}

fn unregister_transfer(transfer_id: &str) {
    transfer_registry().lock().unwrap().remove(transfer_id);
}

/// Cancel an in-flight transfer by its Swift-side UUID. Returns true
/// if a transfer was found and cancelled, false if the id wasn't
/// registered (already finished, never started, or unknown). The
/// running transfer's loop notices on its next chunk boundary and
/// returns `SftpError::Cancelled`.
#[uniffi::export]
pub fn rshell_sftp_cancel(transfer_id: String) -> bool {
    if let Some(token) = transfer_registry().lock().unwrap().get(&transfer_id) {
        token.cancel();
        true
    } else {
        false
    }
}

/// Stream a remote file to a local path. Returns the byte count on
/// success. Publishes `TransferProgress` events on every SFTP chunk so
/// the UI can drive a progress bar — the consumer (Swift
/// `TransferQueueStore`) matches events back to the in-flight transfer
/// by `path`. `expected_size` lets the consumer compute a percentage;
/// pass `0` if unknown.
///
/// `transfer_id` is the caller's stable handle (Swift uses the
/// per-transfer UUID). It's registered in a cancellation registry on
/// entry and removed on exit; `rshell_sftp_cancel(transfer_id)` walks
/// the registry to flip the token, and the chunk loop notices on the
/// next iteration.
#[uniffi::export]
pub fn rshell_sftp_download(
    transfer_id: String,
    connection_id: String,
    remote_path: String,
    local_path: String,
    expected_size: u64,
) -> Result<u64, SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();
    let remote_for_event = remote_path.clone();
    let token = register_transfer(&transfer_id);
    let transfer_id_for_cleanup = transfer_id.clone();

    let result = bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&conn_id)
            .await
            .ok_or_else(|| SftpError::NotConnected {
                connection_id: conn_id.clone(),
            })?;

        let event_tx = r_shell_core::event_bus::event_sender();
        let conn_id_for_progress = conn_id.clone();
        let remote_for_progress = remote_for_event.clone();

        let outcome = {
            let guard = client.read().await;
            guard
                .download_file_with_progress(
                    &remote_path,
                    &local_path,
                    |bytes| {
                        if let Some(tx) = event_tx.as_ref() {
                            let _ = tx.send(r_shell_core::event_bus::CoreEvent::TransferProgress {
                                connection_id: conn_id_for_progress.clone(),
                                path: remote_for_progress.clone(),
                                bytes_transferred: bytes,
                                total_bytes: expected_size,
                            });
                        }
                    },
                    Some(&token),
                )
                .await
        };

        match outcome {
            Ok(bytes) => Ok(bytes),
            Err(_) if token.is_cancelled() => Err(SftpError::Cancelled),
            Err(e) => Err(SftpError::Other { detail: e.to_string() }),
        }
    });

    unregister_transfer(&transfer_id_for_cleanup);
    result
}

/// Stream a local file to a remote path. See `rshell_sftp_download` for
/// the progress-event contract and the cancellation registry. The
/// local file is `stat`'d once before the transfer so progress events
/// carry a meaningful total.
#[uniffi::export]
pub fn rshell_sftp_upload(
    transfer_id: String,
    connection_id: String,
    local_path: String,
    remote_path: String,
) -> Result<u64, SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();
    let remote_for_event = remote_path.clone();

    let total_bytes = std::fs::metadata(&local_path).map(|m| m.len()).unwrap_or(0);
    let token = register_transfer(&transfer_id);
    let transfer_id_for_cleanup = transfer_id.clone();

    let result = bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&conn_id)
            .await
            .ok_or_else(|| SftpError::NotConnected {
                connection_id: conn_id.clone(),
            })?;

        let event_tx = r_shell_core::event_bus::event_sender();
        let conn_id_for_progress = conn_id.clone();
        let remote_for_progress = remote_for_event.clone();

        let outcome = {
            let guard = client.read().await;
            guard
                .upload_file_with_progress(
                    &local_path,
                    &remote_path,
                    |bytes| {
                        if let Some(tx) = event_tx.as_ref() {
                            let _ = tx.send(r_shell_core::event_bus::CoreEvent::TransferProgress {
                                connection_id: conn_id_for_progress.clone(),
                                path: remote_for_progress.clone(),
                                bytes_transferred: bytes,
                                total_bytes,
                            });
                        }
                    },
                    Some(&token),
                )
                .await
        };

        match outcome {
            Ok(bytes) => Ok(bytes),
            Err(_) if token.is_cancelled() => Err(SftpError::Cancelled),
            Err(e) => Err(SftpError::Other { detail: e.to_string() }),
        }
    });

    unregister_transfer(&transfer_id_for_cleanup);
    result
}

/// Create a directory on the remote. Fails if the parent doesn't
/// exist or the name is already taken.
#[uniffi::export]
pub fn rshell_sftp_create_dir(connection_id: String, path: String) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        guard
            .create_dir(&path)
            .await
            .map_err(|e| SftpError::Other { detail: e.to_string() })
    })
}

/// Rename or move a file or directory.
#[uniffi::export]
pub fn rshell_sftp_rename(
    connection_id: String,
    old_path: String,
    new_path: String,
) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        guard
            .rename(&old_path, &new_path)
            .await
            .map_err(|e| SftpError::Other { detail: e.to_string() })
    })
}

/// Delete a regular file. For directories, use `rshell_sftp_delete_dir`.
#[uniffi::export]
pub fn rshell_sftp_delete_file(connection_id: String, path: String) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        guard
            .delete_file(&path)
            .await
            .map_err(|e| SftpError::Other { detail: e.to_string() })
    })
}

/// Delete an empty directory. Recursive removal is the UI's
/// responsibility — list_dir + per-entry delete in a loop with progress.
#[uniffi::export]
pub fn rshell_sftp_delete_dir(connection_id: String, path: String) -> Result<(), SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&connection_id)
            .await
            .ok_or(SftpError::NotConnected {
                connection_id: connection_id.clone(),
            })?;
        let guard = client.read().await;
        guard
            .delete_dir(&path)
            .await
            .map_err(|e| SftpError::Other { detail: e.to_string() })
    })
}

#[uniffi::export]
pub fn rshell_sftp_list_dir(
    connection_id: String,
    path: String,
) -> Result<Vec<FfiFileEntry>, SftpError> {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id = connection_id.clone();

    bridge.runtime.block_on(async move {
        let client = cm
            .get_connection(&conn_id)
            .await
            .ok_or_else(|| SftpError::NotConnected {
                connection_id: conn_id.clone(),
            })?;

        let entries = {
            let guard = client.read().await;
            guard
                .list_dir(&path)
                .await
                .map_err(|e| SftpError::Other { detail: e.to_string() })?
        };

        Ok(entries
            .into_iter()
            .map(|e| FfiFileEntry {
                name: e.name,
                size: e.size,
                modified: e.modified,
                permissions: e.permissions,
                kind: match e.file_type {
                    r_shell_core::sftp_client::FileEntryType::File => FfiFileKind::File,
                    r_shell_core::sftp_client::FileEntryType::Directory => FfiFileKind::Directory,
                    r_shell_core::sftp_client::FileEntryType::Symlink => FfiFileKind::Symlink,
                },
            })
            .collect())
    })
}

/// Forget a stored host-key entry. Called from the Swift "Trust new key"
/// flow after a `HostKeyMismatch` so the next connect TOFU-trusts the
/// new fingerprint. Returns `success: true, value: "true"` if an entry
/// was removed, `success: true, value: "false"` if there was nothing
/// to remove, or `success: false, error: ...` on disk I/O failure.
#[uniffi::export]
pub fn rshell_forget_host_key(host: String, port: u16) -> FfiResult {
    let bridge = MacOsBridge::global();
    let store = bridge.connection_manager.host_keys();
    match bridge
        .runtime
        .block_on(async move { store.forget(&host, port).await })
    {
        Ok(removed) => FfiResult {
            success: true,
            error: None,
            value: Some(removed.to_string()),
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
