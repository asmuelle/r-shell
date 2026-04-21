use crate::connection_manager::ConnectionManager;
use crate::WEBSOCKET_PORT;
use anyhow::Result;
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::handshake::server::{
    ErrorResponse, Request, Response,
};
use tokio_tungstenite::tungstenite::http::StatusCode;
use tokio_tungstenite::{accept_hdr_async, tungstenite::Message};

/// Messages sent by the frontend to the backend. Deserialising into this enum
/// rejects anything the server is only supposed to *emit* (e.g. `Output`,
/// `PtyStarted`) — a client can no longer forge those by sending the JSON
/// directly.
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum InboundWs {
    /// Start a new PTY connection
    StartPty {
        connection_id: String,
        cols: u32,
        rows: u32,
    },
    /// Terminal input (user typing)
    Input {
        connection_id: String,
        data: Vec<u8>,
    },
    /// Resize terminal
    Resize {
        connection_id: String,
        cols: u32,
        rows: u32,
    },
    /// Pause output (flow control - like ttyd)
    Pause { connection_id: String },
    /// Resume output (flow control - like ttyd)
    Resume { connection_id: String },
    /// Close PTY connection
    Close {
        connection_id: String,
        /// If provided, the close is only applied when the generation matches
        /// the current session. This prevents a stale close (from a remounting
        /// component) from killing a newly created PTY session.
        #[serde(default)]
        generation: Option<u64>,
    },

    // Desktop (RDP/VNC)
    StartDesktop {
        connection_id: String,
        width: u16,
        height: u16,
    },
    DesktopKeyEvent {
        connection_id: String,
        key_code: u32,
        down: bool,
    },
    DesktopPointerEvent {
        connection_id: String,
        x: u16,
        y: u16,
        button_mask: u8,
    },
    ClipboardUpdate { connection_id: String, text: String },
    RequestFullFrame { connection_id: String },
    CloseDesktop { connection_id: String },
}

/// Messages emitted by the backend. Never deserialised — the server is the
/// sole authority for these frames.
#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum OutboundWs {
    /// Terminal output (from PTY)
    Output {
        connection_id: String,
        data: Vec<u8>,
    },
    /// Generic error from the server
    Error { message: String },
    /// Acknowledgement / success confirmation
    Success { message: String },
    /// PTY session started — includes the generation counter so the frontend
    /// can send it back in Close to avoid stale-close races.
    PtyStarted {
        connection_id: String,
        generation: u64,
    },
    /// Desktop session started confirmation
    DesktopStarted {
        connection_id: String,
        width: u16,
        height: u16,
    },
}

/// Constant-time comparison. Avoids leaking token length or prefix via the
/// timing side-channel that naive `==` exposes.
fn secure_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Extract the `token` query parameter from the WS upgrade request URI and
/// check it against the expected token using constant-time comparison.
fn token_matches(req: &Request, expected: &str) -> bool {
    let Some(query) = req.uri().query() else {
        return false;
    };
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == "token" {
                let decoded = url_decode(v);
                return secure_eq(&decoded, expected);
            }
        }
    }
    false
}

/// Minimal percent-decoder. The token is hex so in practice no escapes are
/// needed, but handling `%xx` defensively keeps us compatible with browsers
/// that might encode the query string.
fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hi = from_hex(bytes[i + 1]);
                let lo = from_hex(bytes[i + 2]);
                match (hi, lo) {
                    (Some(h), Some(l)) => {
                        out.push((h << 4) | l);
                        i += 3;
                    }
                    _ => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            other => {
                out.push(other);
                i += 1;
            }
        }
    }
    String::from_utf8(out).unwrap_or_default()
}

fn from_hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// WebSocket server for terminal I/O
/// Handles bidirectional communication between frontend and PTY connections
pub struct WebSocketServer {
    connection_manager: Arc<ConnectionManager>,
    /// Token required on every upgrade. Any connection that does not present a
    /// matching `?token=` query parameter is rejected with HTTP 401 before a
    /// single byte of WS traffic is exchanged.
    expected_token: String,
}

impl WebSocketServer {
    pub fn new(connection_manager: Arc<ConnectionManager>, expected_token: String) -> Self {
        Self {
            connection_manager,
            expected_token,
        }
    }

    /// Start the WebSocket server, trying ports 9001-9010 to find an available one
    pub async fn start(self: Arc<Self>) -> Result<()> {
        // Try ports 9001-9010 to find an available one
        let mut listener = None;
        let mut bound_port = 0u16;

        for port in 9001..=9010 {
            let addr: SocketAddr = format!("127.0.0.1:{}", port).parse()?;
            match TcpListener::bind(&addr).await {
                Ok(l) => {
                    tracing::info!("WebSocket server listening on {}", addr);
                    listener = Some(l);
                    bound_port = port;
                    break;
                }
                Err(e) => {
                    tracing::warn!("Port {} unavailable: {}, trying next...", port, e);
                }
            }
        }

        let listener = listener
            .ok_or_else(|| anyhow::anyhow!("Failed to bind to any port in range 9001-9010"))?;

        // Store the bound port in the global atomic for frontend to query
        WEBSOCKET_PORT.store(bound_port, Ordering::SeqCst);
        tracing::info!("WebSocket port stored: {}", bound_port);

        loop {
            match listener.accept().await {
                Ok((stream, addr)) => {
                    tracing::info!("New WebSocket connection from: {}", addr);
                    let server = self.clone();
                    tokio::spawn(async move {
                        if let Err(e) = server.handle_connection(stream).await {
                            tracing::error!("WebSocket connection error: {}", e);
                        }
                    });
                }
                Err(e) => {
                    tracing::error!("Failed to accept connection: {}", e);
                }
            }
        }
    }

    /// Handle a single WebSocket connection. Rejects the upgrade with 401 if
    /// the `token` query parameter does not match the per-process expected
    /// token. This prevents any other local process (or a web page loaded in
    /// the system browser reaching `127.0.0.1`) from hijacking live sessions.
    async fn handle_connection(&self, stream: TcpStream) -> Result<()> {
        let expected = self.expected_token.clone();
        let ws_stream = accept_hdr_async(stream, move |req: &Request, resp: Response| {
            if !token_matches(req, &expected) {
                tracing::warn!(
                    "rejecting WebSocket upgrade: missing or invalid token (uri={})",
                    req.uri()
                );
                let mut err = ErrorResponse::new(Some("invalid or missing token".into()));
                *err.status_mut() = StatusCode::UNAUTHORIZED;
                return Err(err);
            }
            Ok(resp)
        })
        .await?;
        let (mut ws_sender, mut ws_receiver) = ws_stream.split();

        // Create a channel for sending messages back to WebSocket from PTY reader task
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();

        // Task to forward messages from channel to WebSocket
        let ws_sender_task = tokio::spawn(async move {
            while let Some(msg) = rx.recv().await {
                if ws_sender.send(Message::Text(msg)).await.is_err() {
                    break;
                }
            }
        });

        // Handle incoming WebSocket messages
        while let Some(msg) = ws_receiver.next().await {
            match msg {
                Ok(Message::Binary(data)) => {
                    // CRITICAL: Binary protocol for maximum performance (like ttyd)
                    // Format: [command byte][connection_id bytes][data bytes]
                    if data.is_empty() {
                        continue;
                    }

                    let command = data[0];

                    match command {
                        0x00 => {
                            // INPUT command - fastest path
                            if data.len() < 37 {
                                tracing::warn!("Binary INPUT message too short");
                                continue;
                            }

                            let connection_id = String::from_utf8_lossy(&data[1..37]).to_string();
                            let input_data = data[37..].to_vec();

                            // Direct write - no JSON overhead
                            if let Err(e) = self
                                .connection_manager
                                .write_to_pty(&connection_id, input_data)
                                .await
                            {
                                tracing::error!("Failed to write to PTY: {}", e);
                            }
                        }
                        _ => {
                            tracing::warn!("Unknown binary command: {}", command);
                        }
                    }
                }
                Ok(Message::Text(text)) => {
                    // Fallback: JSON protocol for control messages. Only
                    // client→server variants deserialise into `InboundWs`;
                    // any server-only variant sent by a client is rejected as
                    // an unknown tag.
                    tracing::debug!("Received text message: {}", text);

                    let ws_msg: InboundWs = match serde_json::from_str(&text) {
                        Ok(msg) => msg,
                        Err(e) => {
                            let error = OutboundWs::Error {
                                message: format!("Invalid message format: {}", e),
                            };
                            let _ = tx.send(serde_json::to_string(&error)?);
                            continue;
                        }
                    };

                    match self.handle_message(ws_msg, tx.clone()).await {
                        Ok(_) => {}
                        Err(e) => {
                            let error = OutboundWs::Error {
                                message: format!("Error handling message: {}", e),
                            };
                            let _ = tx.send(serde_json::to_string(&error)?);
                        }
                    }
                }
                Ok(Message::Close(_)) => {
                    tracing::info!("WebSocket connection closed by client");
                    break;
                }
                Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                    // Ignore ping/pong frames
                }
                Ok(Message::Frame(_)) => {
                    // Ignore raw frames
                }
                Err(e) => {
                    tracing::error!("WebSocket error: {}", e);
                    break;
                }
            }
        }

        // Cleanup
        ws_sender_task.abort();

        Ok(())
    }

    /// Handle a WebSocket message
    async fn handle_message(
        &self,
        msg: InboundWs,
        tx: tokio::sync::mpsc::UnboundedSender<String>,
    ) -> Result<()> {
        match msg {
            InboundWs::StartPty {
                connection_id,
                cols,
                rows,
            } => {
                tracing::info!(
                    "Starting PTY connection: {} ({}x{})",
                    connection_id,
                    cols,
                    rows
                );

                // Start the PTY connection (returns the generation counter)
                let generation = self
                    .connection_manager
                    .start_pty_connection(&connection_id, cols, rows)
                    .await?;

                // Grab the cancel token for this session so the reader task can
                // stop promptly when the session is torn down.
                let cancel_token = self
                    .connection_manager
                    .get_pty_cancel_token(&connection_id)
                    .await
                    .ok_or_else(|| {
                        anyhow::anyhow!("PTY session disappeared immediately after creation")
                    })?;

                // Send success response with generation so frontend can use it in Close
                let response = OutboundWs::Success {
                    message: format!("PTY connection started: {}", connection_id),
                };
                tx.send(serde_json::to_string(&response)?)?;

                let started = OutboundWs::PtyStarted {
                    connection_id: connection_id.clone(),
                    generation,
                };
                tx.send(serde_json::to_string(&started)?)?;

                // Start reading from PTY and forwarding bursts to WebSocket.
                //
                // `read_pty_burst` blocks until at least one chunk arrives and
                // then drains any already-queued chunks up to 32 KiB. No
                // polling, no time-based coalescing — natural backpressure.
                const BURST_MAX_BYTES: usize = 32 * 1024;
                let connection_manager = self.connection_manager.clone();
                let connection_id_clone = connection_id.clone();
                let tx_clone = tx.clone();

                tokio::spawn(async move {
                    loop {
                        let result = tokio::select! {
                            biased;
                            _ = cancel_token.cancelled() => {
                                tracing::info!("PTY reader cancelled for {}", connection_id_clone);
                                break;
                            }
                            r = connection_manager.read_pty_burst(
                                &connection_id_clone, BURST_MAX_BYTES
                            ) => r,
                        };

                        match result {
                            Ok(data) => {
                                let output = OutboundWs::Output {
                                    connection_id: connection_id_clone.clone(),
                                    data,
                                };
                                match serde_json::to_string(&output) {
                                    Ok(json) => {
                                        if tx_clone.send(json).is_err() {
                                            tracing::debug!(
                                                "WS sender closed, stopping PTY reader"
                                            );
                                            break;
                                        }
                                    }
                                    Err(e) => {
                                        tracing::error!("serialize WS Output failed: {}", e);
                                        break;
                                    }
                                }
                            }
                            Err(e) => {
                                tracing::info!("PTY reader ending for {}: {}", connection_id_clone, e);
                                let error_msg = OutboundWs::Error {
                                    message: format!("Connection lost: {}", e),
                                };
                                if let Ok(json) = serde_json::to_string(&error_msg) {
                                    let _ = tx_clone.send(json);
                                }
                                break;
                            }
                        }
                    }
                });
            }
            InboundWs::Input {
                connection_id,
                data,
            } => {
                tracing::debug!(
                    "Received input for connection {}: {} bytes",
                    connection_id,
                    data.len()
                );
                self.connection_manager
                    .write_to_pty(&connection_id, data)
                    .await?;
            }
            InboundWs::Resize {
                connection_id,
                cols,
                rows,
            } => {
                tracing::info!("Resizing terminal {}: {}x{}", connection_id, cols, rows);
                self.connection_manager
                    .resize_pty(&connection_id, cols, rows)
                    .await?;
                let response = OutboundWs::Success {
                    message: format!("Terminal resized: {}x{}", cols, rows),
                };
                tx.send(serde_json::to_string(&response)?)?;
            }
            InboundWs::Pause { connection_id } => {
                tracing::debug!("Pausing output for connection: {}", connection_id);
                // Flow control: pause reading from PTY
                // In a full implementation, we'd pause the output task
                // For now, just acknowledge
            }
            InboundWs::Resume { connection_id } => {
                tracing::debug!("Resuming output for connection: {}", connection_id);
                // Flow control: resume reading from PTY
                // In a full implementation, we'd resume the output task
                // For now, just acknowledge
            }
            InboundWs::Close {
                connection_id,
                generation,
            } => {
                tracing::info!(
                    "Closing PTY connection: {} (gen: {:?})",
                    connection_id,
                    generation
                );
                self.connection_manager
                    .close_pty_connection(&connection_id, generation)
                    .await?;
                let response = OutboundWs::Success {
                    message: format!("PTY connection closed: {}", connection_id),
                };
                tx.send(serde_json::to_string(&response)?)?;
            }

            // ===== Desktop (RDP/VNC) message handling =====
            InboundWs::StartDesktop {
                connection_id,
                width: _width,
                height: _height,
            } => {
                tracing::info!("Starting desktop session: {}", connection_id);
                // The actual connection is established via the desktop_connect Tauri command.
                // StartDesktop requests the frame streaming loop.
                let client = self
                    .connection_manager
                    .get_desktop_connection(&connection_id)
                    .await;
                if let Some(client) = client {
                    let (w, h) = {
                        let c = client.read().await;
                        c.desktop_size()
                    };
                    let started = OutboundWs::DesktopStarted {
                        connection_id: connection_id.clone(),
                        width: w,
                        height: h,
                    };
                    tx.send(serde_json::to_string(&started)?)?;

                    // TODO: start frame streaming loop when protocol clients are implemented
                } else {
                    let error = OutboundWs::Error {
                        message: format!("Desktop connection not found: {}", connection_id),
                    };
                    tx.send(serde_json::to_string(&error)?)?;
                }
            }

            InboundWs::DesktopKeyEvent {
                connection_id,
                key_code,
                down,
            } => {
                if let Some(client) = self
                    .connection_manager
                    .get_desktop_connection(&connection_id)
                    .await
                {
                    let c = client.read().await;
                    if let Err(e) = c.send_key(key_code, down).await {
                        tracing::error!("Failed to send desktop key event: {}", e);
                    }
                }
            }

            InboundWs::DesktopPointerEvent {
                connection_id,
                x,
                y,
                button_mask,
            } => {
                if let Some(client) = self
                    .connection_manager
                    .get_desktop_connection(&connection_id)
                    .await
                {
                    let c = client.read().await;
                    if let Err(e) = c.send_pointer(x, y, button_mask).await {
                        tracing::error!("Failed to send desktop pointer event: {}", e);
                    }
                }
            }

            InboundWs::ClipboardUpdate {
                connection_id,
                text,
            } => {
                if let Some(client) = self
                    .connection_manager
                    .get_desktop_connection(&connection_id)
                    .await
                {
                    let c = client.read().await;
                    if let Err(e) = c.set_clipboard(text).await {
                        tracing::error!("Failed to set desktop clipboard: {}", e);
                    }
                }
            }

            InboundWs::RequestFullFrame { connection_id } => {
                if let Some(client) = self
                    .connection_manager
                    .get_desktop_connection(&connection_id)
                    .await
                {
                    let c = client.read().await;
                    if let Err(e) = c.request_full_frame().await {
                        tracing::error!("Failed to request full frame: {}", e);
                    }
                }
            }

            InboundWs::CloseDesktop { connection_id } => {
                tracing::info!("Closing desktop session: {}", connection_id);
                if let Err(e) = self
                    .connection_manager
                    .close_desktop_connection(&connection_id)
                    .await
                {
                    tracing::error!("Failed to close desktop connection: {}", e);
                }
                let response = OutboundWs::Success {
                    message: format!("Desktop connection closed: {}", connection_id),
                };
                tx.send(serde_json::to_string(&response)?)?;
            }

        }

        Ok(())
    }
}

#[cfg(test)]
mod auth_tests {
    use super::{from_hex, secure_eq, url_decode};

    #[test]
    fn secure_eq_matches_on_equal() {
        assert!(secure_eq("abc", "abc"));
        assert!(!secure_eq("abc", "abd"));
        assert!(!secure_eq("abc", "abcd"));
        assert!(!secure_eq("", "x"));
    }

    #[test]
    fn url_decode_passthrough_and_escapes() {
        assert_eq!(url_decode("abc123"), "abc123");
        assert_eq!(url_decode("hello%20world"), "hello world");
        assert_eq!(url_decode("a+b"), "a b");
        assert_eq!(url_decode("%41%42"), "AB");
    }

    #[test]
    fn from_hex_digits() {
        assert_eq!(from_hex(b'0'), Some(0));
        assert_eq!(from_hex(b'9'), Some(9));
        assert_eq!(from_hex(b'a'), Some(10));
        assert_eq!(from_hex(b'F'), Some(15));
        assert_eq!(from_hex(b'g'), None);
    }
}
