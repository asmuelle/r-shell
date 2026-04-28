//! Remote desktop (RDP / VNC) lifecycle and input forwarding.

use r_shell_core::connection_manager::ConnectionManager;
use std::sync::Arc;
use tauri::State;

/// Connect to a remote desktop via RDP or VNC
#[tauri::command]
pub async fn desktop_connect(
    request: r_shell_core::desktop_protocol::DesktopConnectRequest,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<r_shell_core::desktop_protocol::DesktopConnectResponse, String> {
    tracing::info!(
        "Desktop connect: {} ({:?}) to {}:{}",
        request.connection_id,
        request.protocol,
        request.host,
        request.port
    );

    let (width, height) = state
        .create_desktop_connection(request.connection_id.clone(), &request)
        .await
        .map_err(|e| e.to_string())?;

    Ok(r_shell_core::desktop_protocol::DesktopConnectResponse { width, height })
}

#[tauri::command]
pub async fn desktop_disconnect(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<(), String> {
    tracing::info!("Desktop disconnect: {}", connection_id);
    state
        .close_desktop_connection(&connection_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn desktop_send_key(
    connection_id: String,
    key_code: u32,
    down: bool,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<(), String> {
    let client = state
        .get_desktop_connection(&connection_id)
        .await
        .ok_or_else(|| format!("Desktop connection not found: {}", connection_id))?;
    let c = client.read().await;
    c.send_key(key_code, down).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn desktop_send_pointer(
    connection_id: String,
    x: u16,
    y: u16,
    button_mask: u8,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<(), String> {
    let client = state
        .get_desktop_connection(&connection_id)
        .await
        .ok_or_else(|| format!("Desktop connection not found: {}", connection_id))?;
    let c = client.read().await;
    c.send_pointer(x, y, button_mask)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn desktop_request_frame(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<(), String> {
    let client = state
        .get_desktop_connection(&connection_id)
        .await
        .ok_or_else(|| format!("Desktop connection not found: {}", connection_id))?;
    let c = client.read().await;
    c.request_full_frame().await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn desktop_set_clipboard(
    connection_id: String,
    text: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<(), String> {
    let client = state
        .get_desktop_connection(&connection_id)
        .await
        .ok_or_else(|| format!("Desktop connection not found: {}", connection_id))?;
    let c = client.read().await;
    c.set_clipboard(text).await.map_err(|e| e.to_string())
}

/// Request a remote desktop session to resize to the given dimensions.
/// For RDP: sends a display resize request to the remote server.
/// For VNC: no-op (client-side scaling is used instead).
#[tauri::command]
pub async fn desktop_resize(
    connection_id: String,
    width: u16,
    height: u16,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<(), String> {
    let client = state
        .get_desktop_connection(&connection_id)
        .await
        .ok_or_else(|| format!("Desktop connection not found: {}", connection_id))?;
    let mut c = client.write().await;
    c.resize(width, height).await.map_err(|e| e.to_string())
}
