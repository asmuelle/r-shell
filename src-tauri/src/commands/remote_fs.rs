//! Unified file operations that dispatch to whichever transport backs the
//! connection (SFTP, FTP, or an existing SSH session for the integrated file
//! browser).

use crate::connection_manager::ConnectionManager;
use crate::sftp_client::FileEntry;
use std::sync::Arc;
use tauri::State;

use super::{CommandResponse, FileTransferResponse};

#[tauri::command]
pub async fn list_remote_files(
    connection_id: String,
    path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<Vec<FileEntry>, String> {
    let conn_type = state
        .get_connection_type(&connection_id)
        .await
        .ok_or_else(|| format!("No file connection found for '{}'", connection_id))?;

    match conn_type.as_str() {
        "SFTP" => {
            let client = state
                .get_sftp_client(&connection_id)
                .await
                .ok_or("SFTP connection not found")?;
            let client = client.read().await;
            client.list_dir(&path).await.map_err(|e| e.to_string())
        }
        "FTP" => {
            let client = state
                .get_ftp_client(&connection_id)
                .await
                .ok_or("FTP connection not found")?;
            let mut client = client.write().await;
            client.list_dir(&path).await.map_err(|e| e.to_string())
        }
        _ => Err(format!("Unsupported protocol: {}", conn_type)),
    }
}

#[tauri::command]
pub async fn download_remote_file(
    connection_id: String,
    remote_path: String,
    local_path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<FileTransferResponse, String> {
    let conn_type = state.get_connection_type(&connection_id).await;

    let result = match conn_type.as_deref() {
        Some("SFTP") => {
            let client = state
                .get_sftp_client(&connection_id)
                .await
                .ok_or("SFTP connection not found".to_string())?;
            let client = client.read().await;
            client.download_file(&remote_path, &local_path).await
        }
        Some("FTP") => {
            let client = state
                .get_ftp_client(&connection_id)
                .await
                .ok_or("FTP connection not found".to_string())?;
            let mut client = client.write().await;
            client.download_file(&remote_path, &local_path).await
        }
        Some("SSH") | None => {
            // Integrated file browser uses a plain SSH connection.
            let connection = state
                .get_connection(&connection_id)
                .await
                .ok_or_else(|| format!("No connection found for '{}'", connection_id))?;
            let client = connection.read().await;
            client.download_file(&remote_path, &local_path).await
        }
        Some(other) => return Err(format!("Unsupported protocol: {}", other)),
    };

    match result {
        Ok(bytes) => Ok(FileTransferResponse {
            success: true,
            bytes_transferred: Some(bytes),
            data: None,
            error: None,
        }),
        Err(e) => Ok(FileTransferResponse {
            success: false,
            bytes_transferred: None,
            data: None,
            error: Some(e.to_string()),
        }),
    }
}

#[tauri::command]
pub async fn upload_remote_file(
    connection_id: String,
    local_path: String,
    remote_path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<FileTransferResponse, String> {
    let conn_type = state.get_connection_type(&connection_id).await;

    let result = match conn_type.as_deref() {
        Some("SFTP") => {
            let client = state
                .get_sftp_client(&connection_id)
                .await
                .ok_or("SFTP connection not found".to_string())?;
            let client = client.read().await;
            client.upload_file(&local_path, &remote_path).await
        }
        Some("FTP") => {
            let client = state
                .get_ftp_client(&connection_id)
                .await
                .ok_or("FTP connection not found".to_string())?;
            let mut client = client.write().await;
            client.upload_file(&local_path, &remote_path).await
        }
        Some("SSH") | None => {
            let connection = state
                .get_connection(&connection_id)
                .await
                .ok_or_else(|| format!("No connection found for '{}'", connection_id))?;
            let client = connection.read().await;
            client.upload_file(&local_path, &remote_path).await
        }
        Some(other) => return Err(format!("Unsupported protocol: {}", other)),
    };

    match result {
        Ok(bytes) => Ok(FileTransferResponse {
            success: true,
            bytes_transferred: Some(bytes),
            data: None,
            error: None,
        }),
        Err(e) => Ok(FileTransferResponse {
            success: false,
            bytes_transferred: None,
            data: None,
            error: Some(e.to_string()),
        }),
    }
}

#[tauri::command]
pub async fn delete_remote_item(
    connection_id: String,
    path: String,
    is_directory: bool,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let conn_type = state
        .get_connection_type(&connection_id)
        .await
        .ok_or_else(|| format!("No file connection found for '{}'", connection_id))?;

    let result = match conn_type.as_str() {
        "SFTP" => {
            let client = state
                .get_sftp_client(&connection_id)
                .await
                .ok_or("SFTP connection not found".to_string())?;
            let client = client.read().await;
            if is_directory {
                client.delete_dir(&path).await
            } else {
                client.delete_file(&path).await
            }
        }
        "FTP" => {
            let client = state
                .get_ftp_client(&connection_id)
                .await
                .ok_or("FTP connection not found".to_string())?;
            let mut client = client.write().await;
            if is_directory {
                client.delete_dir(&path).await
            } else {
                client.delete_file(&path).await
            }
        }
        _ => return Err(format!("Unsupported protocol: {}", conn_type)),
    };

    match result {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some(format!("Deleted: {}", path)),
            error: None,
        }),
        Err(e) => Ok(CommandResponse {
            success: false,
            output: None,
            error: Some(e.to_string()),
        }),
    }
}

#[tauri::command]
pub async fn create_remote_directory(
    connection_id: String,
    path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let conn_type = state
        .get_connection_type(&connection_id)
        .await
        .ok_or_else(|| format!("No file connection found for '{}'", connection_id))?;

    let result = match conn_type.as_str() {
        "SFTP" => {
            let client = state
                .get_sftp_client(&connection_id)
                .await
                .ok_or("SFTP connection not found".to_string())?;
            let client = client.read().await;
            client.create_dir(&path).await
        }
        "FTP" => {
            let client = state
                .get_ftp_client(&connection_id)
                .await
                .ok_or("FTP connection not found".to_string())?;
            let mut client = client.write().await;
            client.create_dir(&path).await
        }
        _ => return Err(format!("Unsupported protocol: {}", conn_type)),
    };

    match result {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some(format!("Created directory: {}", path)),
            error: None,
        }),
        Err(e) => Ok(CommandResponse {
            success: false,
            output: None,
            error: Some(e.to_string()),
        }),
    }
}

#[tauri::command]
pub async fn rename_remote_item(
    connection_id: String,
    old_path: String,
    new_path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let conn_type = state
        .get_connection_type(&connection_id)
        .await
        .ok_or_else(|| format!("No file connection found for '{}'", connection_id))?;

    let result = match conn_type.as_str() {
        "SFTP" => {
            let client = state
                .get_sftp_client(&connection_id)
                .await
                .ok_or("SFTP connection not found".to_string())?;
            let client = client.read().await;
            client.rename(&old_path, &new_path).await
        }
        "FTP" => {
            let client = state
                .get_ftp_client(&connection_id)
                .await
                .ok_or("FTP connection not found".to_string())?;
            let mut client = client.write().await;
            client.rename(&old_path, &new_path).await
        }
        _ => return Err(format!("Unsupported protocol: {}", conn_type)),
    };

    match result {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some(format!("Renamed '{}' to '{}'", old_path, new_path)),
            error: None,
        }),
        Err(e) => Ok(CommandResponse {
            success: false,
            output: None,
            error: Some(e.to_string()),
        }),
    }
}
