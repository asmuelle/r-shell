//! Standalone SFTP connection lifecycle (SSH transport, no PTY).

use crate::connection_manager::ConnectionManager;
use crate::sftp_client::{SftpAuthMethod, SftpConfig};
use serde::Deserialize;
use std::sync::Arc;
use tauri::State;

use super::{
    normalize_optional_non_blank, normalize_optional_trimmed, normalize_required_field,
    AuthMethodTag, CommandResponse,
};

#[derive(Deserialize)]
pub struct SftpConnectRequest {
    pub connection_id: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: AuthMethodTag,
    pub password: Option<String>,
    pub key_path: Option<String>,
    pub passphrase: Option<String>,
}

impl std::fmt::Debug for SftpConnectRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SftpConnectRequest")
            .field("connection_id", &self.connection_id)
            .field("host", &self.host)
            .field("port", &self.port)
            .field("username", &self.username)
            .field("auth_method", &self.auth_method)
            .field(
                "password",
                &self
                    .password
                    .as_ref()
                    .map(|_| "<redacted>")
                    .unwrap_or("<none>"),
            )
            .field("key_path", &self.key_path)
            .field(
                "passphrase",
                &self
                    .passphrase
                    .as_ref()
                    .map(|_| "<redacted>")
                    .unwrap_or("<none>"),
            )
            .finish()
    }
}

#[tauri::command]
pub async fn sftp_connect(
    request: SftpConnectRequest,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let host = normalize_required_field(request.host, "Host")?;
    let username = normalize_required_field(request.username, "Username")?;
    let auth = match request.auth_method {
        AuthMethodTag::Password => SftpAuthMethod::Password {
            password: request.password.unwrap_or_default(),
        },
        AuthMethodTag::PublicKey => SftpAuthMethod::PublicKey {
            key_path: normalize_optional_trimmed(request.key_path)
                .ok_or("Key path required for SFTP")?,
            passphrase: normalize_optional_non_blank(request.passphrase),
        },
    };

    let config = SftpConfig {
        host,
        port: request.port,
        username,
        auth_method: auth,
    };

    match state
        .create_sftp_connection(request.connection_id.clone(), config)
        .await
    {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some(format!("SFTP connected: {}", request.connection_id)),
            error: None,
        }),
        Err(e) => Err(format!("SFTP connection failed: {}", e)),
    }
}

#[tauri::command]
pub async fn sftp_standalone_disconnect(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    match state.close_sftp_connection(&connection_id).await {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some("SFTP disconnected".to_string()),
            error: None,
        }),
        Err(e) => Ok(CommandResponse {
            success: false,
            output: None,
            error: Some(e.to_string()),
        }),
    }
}
