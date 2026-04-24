use crate::desktop_protocol::{DesktopConnectRequest, DesktopProtocol, FrameUpdate};
use crate::ftp_client::FtpClient;
use crate::rdp_client::RdpClient;
use crate::sftp_client::StandaloneSftpClient;
use crate::ssh::{HostKeyStore, PtySession, SshClient, SshConfig};
use crate::vnc_client::VncClient;
use anyhow::Result;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::sync::RwLock;
use tokio_util::sync::CancellationToken;

/// Canonical protocol tag for a managed connection.
///
/// Using an enum instead of a free-form string means every branch that inspects
/// a connection is exhaustiveness-checked and callers can't typo a tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolKind {
    Ssh,
    Sftp,
    Ftp,
    Rdp,
    Vnc,
}

impl ProtocolKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ProtocolKind::Ssh => "SSH",
            ProtocolKind::Sftp => "SFTP",
            ProtocolKind::Ftp => "FTP",
            ProtocolKind::Rdp => "RDP",
            ProtocolKind::Vnc => "VNC",
        }
    }
}

/// A single managed connection, tagged by protocol.
///
/// Each variant owns its own `Arc<RwLock<_>>` — giving per-connection locking
/// granularity, instead of a global map-level RwLock that would serialise
/// every operation across unrelated connections.
pub enum ManagedConnection {
    Ssh(Arc<RwLock<SshClient>>),
    Sftp(Arc<RwLock<StandaloneSftpClient>>),
    Ftp(Arc<RwLock<FtpClient>>),
    Desktop {
        kind: ProtocolKind, // Rdp or Vnc
        client: Arc<RwLock<Box<dyn DesktopProtocol>>>,
    },
}

impl ManagedConnection {
    pub fn kind(&self) -> ProtocolKind {
        match self {
            ManagedConnection::Ssh(_) => ProtocolKind::Ssh,
            ManagedConnection::Sftp(_) => ProtocolKind::Sftp,
            ManagedConnection::Ftp(_) => ProtocolKind::Ftp,
            ManagedConnection::Desktop { kind, .. } => *kind,
        }
    }
}

/// The connection manager owns the mapping from connection_id → its backing
/// protocol state. Previously this was eight parallel hashmaps held together
/// by convention; invariants (e.g. "if connection_types says SFTP, the sftp
/// hashmap contains the id") are now enforced by the variant tag itself.
pub struct ConnectionManager {
    connections: Arc<RwLock<HashMap<String, ManagedConnection>>>,
    pty_sessions: Arc<RwLock<HashMap<String, Arc<PtySession>>>>,
    /// Generation counter per connection_id — incremented on each StartPty.
    /// Used to prevent a stale Close from killing a newly created session.
    pty_generations: Arc<RwLock<HashMap<String, u64>>>,
    pending_connections: Arc<RwLock<HashMap<String, CancellationToken>>>,
    /// Shared TOFU host-key store used by every SSH/SFTP connection.
    host_keys: Arc<HostKeyStore>,
}

impl ConnectionManager {
    pub fn new() -> Self {
        Self::with_host_keys(Arc::new(HostKeyStore::new(HostKeyStore::default_path())))
    }

    pub fn with_host_keys(host_keys: Arc<HostKeyStore>) -> Self {
        Self {
            connections: Arc::new(RwLock::new(HashMap::new())),
            pty_sessions: Arc::new(RwLock::new(HashMap::new())),
            pty_generations: Arc::new(RwLock::new(HashMap::new())),
            pending_connections: Arc::new(RwLock::new(HashMap::new())),
            host_keys,
        }
    }

    // =========================================================================
    // Inspection
    // =========================================================================

    /// Protocol of an existing connection, or None if not registered.
    pub async fn connection_kind(&self, id: &str) -> Option<ProtocolKind> {
        let connections = self.connections.read().await;
        connections.get(id).map(|c| c.kind())
    }

    /// Backward-compatible string form of `connection_kind`. Returns "SSH",
    /// "SFTP", "FTP", "RDP", or "VNC". Prefer `connection_kind` in new code.
    pub async fn get_connection_type(&self, id: &str) -> Option<String> {
        self.connection_kind(id)
            .await
            .map(|k| k.as_str().to_string())
    }

    pub async fn list_connections(&self) -> Vec<String> {
        let connections = self.connections.read().await;
        connections.keys().cloned().collect()
    }

    /// Return the SSH client for a connection if it is an SSH connection.
    pub async fn get_connection(&self, id: &str) -> Option<Arc<RwLock<SshClient>>> {
        let connections = self.connections.read().await;
        match connections.get(id) {
            Some(ManagedConnection::Ssh(c)) => Some(c.clone()),
            _ => None,
        }
    }

    pub async fn get_sftp_client(&self, id: &str) -> Option<Arc<RwLock<StandaloneSftpClient>>> {
        let connections = self.connections.read().await;
        match connections.get(id) {
            Some(ManagedConnection::Sftp(c)) => Some(c.clone()),
            _ => None,
        }
    }

    pub async fn get_ftp_client(&self, id: &str) -> Option<Arc<RwLock<FtpClient>>> {
        let connections = self.connections.read().await;
        match connections.get(id) {
            Some(ManagedConnection::Ftp(c)) => Some(c.clone()),
            _ => None,
        }
    }

    pub async fn get_desktop_connection(
        &self,
        id: &str,
    ) -> Option<Arc<RwLock<Box<dyn DesktopProtocol>>>> {
        let connections = self.connections.read().await;
        match connections.get(id) {
            Some(ManagedConnection::Desktop { client, .. }) => Some(client.clone()),
            _ => None,
        }
    }

    // =========================================================================
    // SSH connection lifecycle (supports cancellation of a pending connect)
    // =========================================================================

    pub async fn create_connection(&self, connection_id: String, config: SshConfig) -> Result<()> {
        let mut client = SshClient::new(self.host_keys.clone());
        let cancel_token = self.register_pending_connection(&connection_id).await;

        let connect_result = tokio::select! {
            res = client.connect(&config) => res,
            _ = cancel_token.cancelled() => Err(anyhow::anyhow!("Connection cancelled by user")),
        };

        self.clear_pending_connection(&connection_id).await;

        connect_result?;

        let mut connections = self.connections.write().await;
        connections.insert(
            connection_id,
            ManagedConnection::Ssh(Arc::new(RwLock::new(client))),
        );

        Ok(())
    }

    async fn register_pending_connection(&self, connection_id: &str) -> CancellationToken {
        let token = CancellationToken::new();
        let mut pending = self.pending_connections.write().await;
        pending.insert(connection_id.to_string(), token.clone());
        token
    }

    async fn clear_pending_connection(&self, connection_id: &str) {
        let mut pending = self.pending_connections.write().await;
        pending.remove(connection_id);
    }

    pub async fn cancel_pending_connection(&self, connection_id: &str) -> bool {
        let mut pending = self.pending_connections.write().await;
        if let Some(token) = pending.remove(connection_id) {
            token.cancel();
            true
        } else {
            false
        }
    }

    /// Close the SSH connection for `connection_id` (if it is SSH). Also tears
    /// down any associated PTY session and prunes the generation counter so it
    /// cannot leak across reconnects.
    pub async fn close_connection(&self, connection_id: &str) -> Result<()> {
        // Tear down any PTY session first so its tasks unblock before we drop
        // the SSH handle they depend on.
        {
            let mut pty_sessions = self.pty_sessions.write().await;
            if let Some(session) = pty_sessions.remove(connection_id) {
                session.cancel.cancel();
            }
        }
        {
            let mut generations = self.pty_generations.write().await;
            generations.remove(connection_id);
        }

        let mut connections = self.connections.write().await;
        if let Some(ManagedConnection::Ssh(client)) = connections.remove(connection_id) {
            let mut client = client.write().await;
            client.disconnect().await?;
        }
        Ok(())
    }

    // =========================================================================
    // PTY (interactive shell) management — only valid on SSH connections.
    // =========================================================================

    /// Start a PTY shell connection (like ttyd does).
    /// Enables interactive commands: vim, less, more, top, htop, etc.
    pub async fn start_pty_connection(
        &self,
        connection_id: &str,
        cols: u32,
        rows: u32,
    ) -> Result<u64> {
        let client = self
            .get_connection(connection_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("Connection not found"))?;

        // Cancel and remove any existing PTY session for this connection first.
        // This ensures the old SSH channel and reader task are torn down before
        // we create a new one, preventing orphaned sessions.
        {
            let mut pty_sessions = self.pty_sessions.write().await;
            if let Some(old_session) = pty_sessions.remove(connection_id) {
                old_session.cancel.cancel();
                tracing::info!("Cancelled old PTY session for {}", connection_id);
            }
        }

        let pty = {
            let client = client.read().await;
            client.create_pty_session(cols, rows).await?
        };

        // Bump generation so any in-flight Close for the old session is ignored.
        let mut generations = self.pty_generations.write().await;
        let gen = generations.entry(connection_id.to_string()).or_insert(0);
        *gen += 1;
        let current_gen = *gen;
        drop(generations);

        let mut pty_sessions = self.pty_sessions.write().await;
        pty_sessions.insert(connection_id.to_string(), Arc::new(pty));

        Ok(current_gen)
    }

    /// Send data to PTY (user input).
    ///
    /// Backpressure: if the input channel is full we await `send`, preserving
    /// keystroke order.
    pub async fn write_to_pty(&self, connection_id: &str, data: Vec<u8>) -> Result<()> {
        let tx = {
            let pty_sessions = self.pty_sessions.read().await;
            let pty = pty_sessions
                .get(connection_id)
                .ok_or_else(|| anyhow::anyhow!("PTY connection not found"))?;
            pty.input_tx.clone()
        };

        tx.send(data)
            .await
            .map_err(|_| anyhow::anyhow!("PTY channel closed"))
    }

    /// Read a burst of PTY output — blocks until data arrives, then drains any
    /// additional already-queued chunks up to `max_bytes`.
    pub async fn read_pty_burst(&self, connection_id: &str, max_bytes: usize) -> Result<Vec<u8>> {
        let pty = {
            let pty_sessions = self.pty_sessions.read().await;
            pty_sessions
                .get(connection_id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("PTY connection not found"))?
        };

        let mut rx = pty.output_rx.lock().await;

        let mut out = match rx.recv().await {
            Some(data) => data,
            None => return Err(anyhow::anyhow!("PTY connection closed")),
        };

        while out.len() < max_bytes {
            match rx.try_recv() {
                Ok(more) => out.extend_from_slice(&more),
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => break,
            }
        }

        Ok(out)
    }

    /// Close PTY connection, but only if the generation matches.
    pub async fn close_pty_connection(
        &self,
        connection_id: &str,
        expected_gen: Option<u64>,
    ) -> Result<()> {
        if let Some(gen) = expected_gen {
            let generations = self.pty_generations.read().await;
            let current_gen = generations.get(connection_id).copied().unwrap_or(0);
            if current_gen != gen {
                tracing::info!(
                    "Ignoring stale Close for {} (gen {} != current {})",
                    connection_id,
                    gen,
                    current_gen
                );
                return Ok(());
            }
        }
        let mut pty_sessions = self.pty_sessions.write().await;
        if let Some(session) = pty_sessions.remove(connection_id) {
            session.cancel.cancel();
        }
        Ok(())
    }

    /// Get the cancellation token for a PTY session (used by WebSocket reader tasks).
    pub async fn get_pty_cancel_token(&self, connection_id: &str) -> Option<CancellationToken> {
        let sessions = self.pty_sessions.read().await;
        sessions.get(connection_id).map(|s| s.cancel.clone())
    }

    /// Resize PTY terminal (send window-change to remote SSH channel)
    pub async fn resize_pty(&self, connection_id: &str, cols: u32, rows: u32) -> Result<()> {
        let pty_sessions = self.pty_sessions.read().await;
        let pty = pty_sessions
            .get(connection_id)
            .ok_or_else(|| anyhow::anyhow!("PTY connection not found"))?;

        pty.resize_tx
            .send((cols, rows))
            .await
            .map_err(|_| anyhow::anyhow!("PTY resize channel closed"))
    }

    // =========================================================================
    // Standalone SFTP
    // =========================================================================

    pub async fn create_sftp_connection(
        &self,
        connection_id: String,
        config: crate::sftp_client::SftpConfig,
    ) -> Result<()> {
        let client = StandaloneSftpClient::connect(&config, self.host_keys.clone()).await?;
        let mut connections = self.connections.write().await;
        connections.insert(
            connection_id,
            ManagedConnection::Sftp(Arc::new(RwLock::new(client))),
        );
        Ok(())
    }

    pub async fn close_sftp_connection(&self, connection_id: &str) -> Result<()> {
        let mut connections = self.connections.write().await;
        if let Some(ManagedConnection::Sftp(client)) = connections.remove(connection_id) {
            let mut client = client.write().await;
            client.disconnect().await?;
        }
        Ok(())
    }

    // =========================================================================
    // FTP / FTPS
    // =========================================================================

    pub async fn create_ftp_connection(
        &self,
        connection_id: String,
        config: crate::ftp_client::FtpConfig,
    ) -> Result<()> {
        let client = FtpClient::connect(&config).await?;
        let mut connections = self.connections.write().await;
        connections.insert(
            connection_id,
            ManagedConnection::Ftp(Arc::new(RwLock::new(client))),
        );
        Ok(())
    }

    pub async fn close_ftp_connection(&self, connection_id: &str) -> Result<()> {
        let mut connections = self.connections.write().await;
        if let Some(ManagedConnection::Ftp(client)) = connections.remove(connection_id) {
            let mut client = client.write().await;
            client.disconnect().await?;
        }
        Ok(())
    }

    // =========================================================================
    // Remote desktop (RDP / VNC)
    // =========================================================================

    pub async fn create_desktop_connection(
        &self,
        connection_id: String,
        request: &DesktopConnectRequest,
    ) -> Result<(u16, u16)> {
        use crate::desktop_protocol::DesktopKind;
        let (kind, client): (ProtocolKind, Box<dyn DesktopProtocol>) = match request.protocol {
            DesktopKind::Rdp => {
                let config = request.to_rdp_config();
                (
                    ProtocolKind::Rdp,
                    Box::new(RdpClient::connect(&config).await?),
                )
            }
            DesktopKind::Vnc => {
                let config = request.to_vnc_config();
                (
                    ProtocolKind::Vnc,
                    Box::new(VncClient::connect(&config).await?),
                )
            }
        };

        let (w, h) = client.desktop_size();

        let mut connections = self.connections.write().await;
        connections.insert(
            connection_id,
            ManagedConnection::Desktop {
                kind,
                client: Arc::new(RwLock::new(client)),
            },
        );

        Ok((w, h))
    }

    pub async fn close_desktop_connection(&self, connection_id: &str) -> Result<()> {
        let mut connections = self.connections.write().await;
        if let Some(ManagedConnection::Desktop { client, .. }) = connections.remove(connection_id) {
            let mut client = client.write().await;
            client.disconnect().await?;
        }
        Ok(())
    }

    /// Start the frame update loop for a desktop connection.
    ///
    /// Not yet wired up to the WebSocket server — kept here so the RDP/VNC
    /// stubs have a concrete dispatch point once the protocol clients gain
    /// real implementations. Remove the allow once a caller appears.
    #[allow(dead_code)]
    pub async fn start_desktop_stream(
        &self,
        connection_id: &str,
        frame_tx: mpsc::UnboundedSender<FrameUpdate>,
        cancel: CancellationToken,
    ) -> Result<()> {
        let client = self
            .get_desktop_connection(connection_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("Desktop connection not found: {}", connection_id))?;
        let client = client.read().await;
        client.start_frame_loop(frame_tx, cancel).await
    }
}

// =============================================================================
// Unit tests
// =============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_new_manager_has_no_connections() {
        let mgr = ConnectionManager::new();
        assert!(mgr.list_connections().await.is_empty());
    }

    #[tokio::test]
    async fn test_connection_kind_returns_none_for_unknown() {
        let mgr = ConnectionManager::new();
        assert!(mgr.connection_kind("unknown-id").await.is_none());
        assert!(mgr.get_connection_type("unknown-id").await.is_none());
    }

    #[tokio::test]
    async fn test_cancel_nonexistent_pending_connection() {
        let mgr = ConnectionManager::new();
        assert!(!mgr.cancel_pending_connection("ghost").await);
    }

    #[tokio::test]
    async fn test_protocol_kind_round_trip() {
        assert_eq!(ProtocolKind::Ssh.as_str(), "SSH");
        assert_eq!(ProtocolKind::Sftp.as_str(), "SFTP");
        assert_eq!(ProtocolKind::Ftp.as_str(), "FTP");
        assert_eq!(ProtocolKind::Rdp.as_str(), "RDP");
        assert_eq!(ProtocolKind::Vnc.as_str(), "VNC");
    }

    #[tokio::test]
    async fn test_close_sftp_of_unknown_id_is_noop() {
        let mgr = ConnectionManager::new();
        let result = mgr.close_sftp_connection("ghost").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_close_ftp_of_unknown_id_is_noop() {
        let mgr = ConnectionManager::new();
        let result = mgr.close_ftp_connection("ghost").await;
        assert!(result.is_ok());
    }
}
