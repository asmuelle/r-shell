//! Shell-based file ops through an SSH connection plus the deprecated
//! `sftp_download_file` / `sftp_upload_file` aliases.
//!
//! The SFTP-subsystem variants live in `remote_fs`; the commands here either
//! shell-exec through the existing SSH connection or use the SSH client's
//! built-in SFTP helpers.

use crate::connection_manager::ConnectionManager;
use crate::ssh::shell::quote as sh_quote;
use std::sync::Arc;
use tauri::State;

use super::{FileTransferRequest, FileTransferResponse};

#[tauri::command]
pub async fn list_files(
    connection_id: String,
    path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<String, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = format!("ls -la --time-style=long-iso {}", sh_quote(&path));

    match client.execute_command(&command).await {
        Ok(output) => Ok(output),
        Err(e) => Err(e.to_string()),
    }
}

/// @deprecated Use `download_remote_file` instead. Kept for backward compatibility.
#[tauri::command]
pub async fn sftp_download_file(
    request: FileTransferRequest,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<FileTransferResponse, String> {
    let connection = state
        .get_connection(&request.connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    if request.local_path.is_empty() {
        match client.download_file_to_memory(&request.remote_path).await {
            Ok(data) => {
                let bytes = data.len() as u64;
                Ok(FileTransferResponse {
                    success: true,
                    bytes_transferred: Some(bytes),
                    data: Some(data),
                    error: None,
                })
            }
            Err(e) => Ok(FileTransferResponse {
                success: false,
                bytes_transferred: None,
                data: None,
                error: Some(e.to_string()),
            }),
        }
    } else {
        match client
            .download_file(&request.remote_path, &request.local_path)
            .await
        {
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
}

/// @deprecated Use `upload_remote_file` instead. Kept for backward compatibility.
#[tauri::command]
pub async fn sftp_upload_file(
    request: FileTransferRequest,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<FileTransferResponse, String> {
    let connection = state
        .get_connection(&request.connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let result = if let Some(data) = &request.data {
        client
            .upload_file_from_bytes(data, &request.remote_path)
            .await
    } else {
        client
            .upload_file(&request.local_path, &request.remote_path)
            .await
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
pub async fn create_directory(
    connection_id: String,
    path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<bool, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = format!("mkdir -p {}", sh_quote(&path));

    client
        .execute_command(&command)
        .await
        .map(|_| true)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn delete_file(
    connection_id: String,
    path: String,
    is_directory: bool,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<bool, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = if is_directory {
        format!("rm -rf {}", sh_quote(&path))
    } else {
        format!("rm -f {}", sh_quote(&path))
    };

    client
        .execute_command(&command)
        .await
        .map(|_| true)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn rename_file(
    connection_id: String,
    old_path: String,
    new_path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<bool, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = format!("mv {} {}", sh_quote(&old_path), sh_quote(&new_path));

    client
        .execute_command(&command)
        .await
        .map(|_| true)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn create_file(
    connection_id: String,
    path: String,
    content: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<bool, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    client
        .upload_file_from_bytes(content.as_bytes(), &path)
        .await
        .map(|_| true)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn read_file_content(
    connection_id: String,
    path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<String, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = format!("cat {}", sh_quote(&path));

    match client.execute_command(&command).await {
        Ok(output) => Ok(output),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
pub async fn copy_file(
    connection_id: String,
    source_path: String,
    dest_path: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<bool, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = format!("cp -r {} {}", sh_quote(&source_path), sh_quote(&dest_path));

    client
        .execute_command(&command)
        .await
        .map(|_| true)
        .map_err(|e| e.to_string())
}
