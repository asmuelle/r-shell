//! Process listing and signal delivery.

use r_shell_core::connection_manager::ConnectionManager;
use r_shell_core::ssh::shell::{validate_pid, validate_signal};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::State;

use super::CommandResponse;

#[derive(Debug, Serialize, Deserialize)]
pub struct ProcessInfo {
    pub pid: String,
    pub user: String,
    pub cpu: String,
    pub mem: String,
    pub command: String,
}

#[derive(Debug, Serialize)]
pub struct ProcessListResponse {
    pub success: bool,
    pub processes: Option<Vec<ProcessInfo>>,
    pub error: Option<String>,
}

#[tauri::command]
pub async fn get_processes(
    connection_id: String,
    sort_by: Option<String>,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<ProcessListResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    // Portable sorting via pipe — `ps aux --sort=` is Linux/procps-ng
    // specific and fails on macOS (BSD ps) and BusyBox.
    let sort_key = match sort_by.as_deref() {
        Some("mem") => "-k4nr",
        _ => "-k3nr",
    };
    let command = format!("ps aux | sort {} | head -50", sort_key);

    match client.execute_command(&command).await {
        Ok(output) => {
            let mut processes = Vec::new();
            for line in output.lines().filter(|l| !l.starts_with("USER ")) {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 11 {
                    processes.push(ProcessInfo {
                        user: parts[0].to_string(),
                        pid: parts[1].to_string(),
                        cpu: parts[2].to_string(),
                        mem: parts[3].to_string(),
                        command: parts[10..].join(" "),
                    });
                }
            }
            Ok(ProcessListResponse {
                success: true,
                processes: Some(processes),
                error: None,
            })
        }
        Err(e) => Ok(ProcessListResponse {
            success: false,
            processes: None,
            error: Some(e.to_string()),
        }),
    }
}

#[tauri::command]
pub async fn kill_process(
    connection_id: String,
    pid: String,
    signal: Option<String>,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    // Validate both pid and signal before interpolating so a malicious value
    // cannot break out of the shell command.
    let sig = signal.unwrap_or_else(|| "15".to_string());
    let sig = validate_signal(&sig)?;
    let pid_ok = validate_pid(&pid)?;
    let command = format!("kill -{} {}", sig, pid_ok);

    match client.execute_command(&command).await {
        Ok(output) => Ok(CommandResponse {
            success: true,
            output: Some(output),
            error: None,
        }),
        Err(e) => Ok(CommandResponse {
            success: false,
            output: None,
            error: Some(e.to_string()),
        }),
    }
}
