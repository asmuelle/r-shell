//! Expose the dynamically-chosen WebSocket port and the per-process auth token
//! to the frontend so it can open an authenticated PTY stream.

/// Get the dynamically assigned WebSocket port for PTY terminal connections
#[tauri::command]
pub async fn get_websocket_port() -> Result<u16, String> {
    use crate::WEBSOCKET_PORT;
    use std::sync::atomic::Ordering;

    let port = WEBSOCKET_PORT.load(Ordering::SeqCst);
    if port == 0 {
        Err("WebSocket server not yet started".to_string())
    } else {
        Ok(port)
    }
}

/// Get the per-process WebSocket auth token. The frontend must include this as
/// the `token` query parameter when opening the WebSocket connection, e.g.
/// `ws://127.0.0.1:9001/?token=...`. Servers reject any upgrade without it.
#[tauri::command]
pub async fn get_websocket_token() -> Result<String, String> {
    crate::WEBSOCKET_AUTH_TOKEN
        .get()
        .cloned()
        .ok_or_else(|| "WebSocket auth token not initialised".to_string())
}
