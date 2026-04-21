mod commands;
mod connection_manager;
mod desktop_protocol;
mod ftp_client;
mod keychain;
mod menu;
mod rdp_client;
mod sftp_client;
mod ssh;
mod vnc_client;
mod websocket_server;

use connection_manager::ConnectionManager;
use std::sync::atomic::AtomicU16;
use std::sync::Arc;
use std::sync::OnceLock;
use websocket_server::WebSocketServer;

// Global atomic to store the WebSocket port (shared between backend and frontend)
pub static WEBSOCKET_PORT: AtomicU16 = AtomicU16::new(0);

/// Per-process auth token required on every WebSocket upgrade. Set once at
/// startup. Callers read it via the `get_websocket_token` Tauri command and
/// include it as the `?token=` query parameter when opening the WS URL.
pub static WEBSOCKET_AUTH_TOKEN: OnceLock<String> = OnceLock::new();

fn generate_auth_token() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Initialize tracing
    tracing_subscriber::fmt::init();

    // Create connection manager
    let connection_manager = Arc::new(ConnectionManager::new());

    // Generate a fresh WebSocket auth token for this process lifetime.
    // Stored in a OnceLock so it cannot be changed after startup.
    let token = generate_auth_token();
    WEBSOCKET_AUTH_TOKEN
        .set(token.clone())
        .expect("WEBSOCKET_AUTH_TOKEN set twice");

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_opener::init())
        .setup({
            let connection_manager_clone = connection_manager.clone();
            move |app| {
                // Install the native menu bar. Runs on every platform; on
                // macOS this becomes the system menu bar, elsewhere it
                // attaches to the main window.
                if let Err(e) = menu::install(app.handle()) {
                    tracing::error!("Failed to install application menu: {}", e);
                }

                // Start WebSocket server for terminal I/O
                // Try ports 9001-9010 to avoid conflicts with other instances
                let ws_server = Arc::new(WebSocketServer::new(
                    connection_manager_clone,
                    token.clone(),
                ));
                tauri::async_runtime::spawn(async move {
                    if let Err(e) = ws_server.start().await {
                        tracing::error!("WebSocket server error: {}", e);
                    }
                });
                Ok(())
            }
        })
        .manage(connection_manager)
        .invoke_handler(tauri::generate_handler![
            commands::ssh_connect,
            commands::ssh_cancel_connect,
            commands::ssh_disconnect,
            commands::ssh_execute_command,
            commands::ssh_tab_complete,
            commands::get_system_stats,
            commands::list_files,
            commands::list_connections,
            commands::sftp_download_file,
            commands::sftp_upload_file,
            commands::get_processes,
            commands::kill_process,
            commands::tail_log,
            commands::list_log_files,
            commands::discover_log_sources,
            commands::read_log,
            commands::search_log,
            commands::get_network_stats,
            commands::get_active_connections,
            commands::get_network_bandwidth,
            commands::get_network_latency,
            commands::get_disk_usage,
            commands::create_directory,
            commands::delete_file,
            commands::rename_file,
            commands::create_file,
            commands::read_file_content,
            commands::copy_file,
            commands::detect_gpu,
            commands::get_gpu_stats,
            commands::get_websocket_port,
            commands::get_websocket_token,
            // macOS Keychain
            commands::keychain_available,
            commands::keychain_save,
            commands::keychain_load,
            commands::keychain_delete,
            commands::keychain_list,
            // Standalone SFTP/FTP commands
            commands::sftp_connect,
            commands::sftp_standalone_disconnect,
            commands::ftp_connect,
            commands::ftp_disconnect,
            // Unified file operation commands
            commands::list_remote_files,
            commands::download_remote_file,
            commands::upload_remote_file,
            commands::delete_remote_item,
            commands::create_remote_directory,
            commands::rename_remote_item,
            // Local filesystem commands
            commands::list_local_files,
            commands::get_home_directory,
            commands::delete_local_item,
            commands::rename_local_item,
            commands::create_local_directory,
            commands::open_in_os,
            // Directory synchronization commands
            commands::list_local_files_recursive,
            commands::list_remote_files_recursive,
            // Desktop (RDP/VNC) commands
            commands::desktop_connect,
            commands::desktop_disconnect,
            commands::desktop_send_key,
            commands::desktop_send_pointer,
            commands::desktop_request_frame,
            commands::desktop_set_clipboard,
            commands::desktop_resize,
            // Note: PTY terminal I/O now uses WebSocket instead of IPC
            // WebSocket server runs on a dynamically assigned port (9001-9010)
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
