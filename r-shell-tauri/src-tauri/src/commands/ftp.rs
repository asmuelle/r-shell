//! FTP / FTPS connection lifecycle.

use r_shell_core::connection_manager::ConnectionManager;
use r_shell_core::ftp_client::FtpConfig;
use serde::Deserialize;
use std::sync::Arc;
use tauri::State;

use super::CommandResponse;

#[derive(Deserialize)]
pub struct FtpConnectRequest {
    pub connection_id: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: Option<String>,
    pub ftps_enabled: bool,
    pub anonymous: bool,
    /// When `ftps_enabled` is true, allow self-signed/invalid TLS certs.
    /// Defaults to false (strict validation).
    #[serde(default)]
    pub allow_invalid_certs: bool,
}

#[tauri::command]
pub async fn ftp_connect(
    request: FtpConnectRequest,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    tracing::info!(
        "ftp_connect: id={}, host={}:{}, user={}, ftps={}, anon={}",
        request.connection_id,
        request.host,
        request.port,
        request.username,
        request.ftps_enabled,
        request.anonymous
    );

    let config = FtpConfig {
        host: request.host,
        port: request.port,
        username: if request.anonymous {
            "anonymous".to_string()
        } else {
            request.username
        },
        password: if request.anonymous {
            "anonymous@".to_string()
        } else {
            request.password.unwrap_or_default()
        },
        ftps_enabled: request.ftps_enabled,
        anonymous: request.anonymous,
        allow_invalid_certs: request.allow_invalid_certs,
    };

    match state
        .create_ftp_connection(request.connection_id.clone(), config)
        .await
    {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some(format!("FTP connected: {}", request.connection_id)),
            error: None,
        }),
        Err(e) => Err(format!("FTP connection failed: {}", e)),
    }
}

#[tauri::command]
pub async fn ftp_disconnect(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    match state.close_ftp_connection(&connection_id).await {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some("FTP disconnected".to_string()),
            error: None,
        }),
        Err(e) => Ok(CommandResponse {
            success: false,
            output: None,
            error: Some(e.to_string()),
        }),
    }
}
