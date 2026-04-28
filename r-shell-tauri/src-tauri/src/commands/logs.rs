//! Log-source discovery, tailing, and searching through an SSH connection.

use r_shell_core::connection_manager::ConnectionManager;
use r_shell_core::ssh::shell::quote as sh_quote;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::State;

use super::CommandResponse;

/// Tag for which backing source a log entry comes from.
///
/// Serialised lowercase (`"file"` / `"journal"` / `"docker"`) — matches both
/// the shape of `LogSource.source_type` the frontend already sees and the
/// inbound `source_type` strings the tail/search handlers accepted before.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LogSourceKind {
    File,
    Journal,
    Docker,
}

#[tauri::command]
pub async fn tail_log(
    connection_id: String,
    log_path: String,
    lines: Option<u32>,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let line_count = lines.unwrap_or(50);
    let command = format!("tail -n {} {}", line_count, sh_quote(&log_path));

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

#[tauri::command]
pub async fn list_log_files(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = "find /var/log -type f -name '*.log' 2>/dev/null | head -50";

    match client.execute_command(command).await {
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

// ---------------------------------------------------------------------------
// Log source discovery (files + journalctl + docker)
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct LogSource {
    pub id: String,
    pub name: String,
    pub source_type: LogSourceKind,
    pub path: String,
    pub category: String,
    pub size_human: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct LogSourcesResponse {
    pub success: bool,
    pub sources: Vec<LogSource>,
    pub error: Option<String>,
}

fn categorize_log_file(name: &str) -> String {
    let lower = name.to_lowercase();
    if lower.contains("auth") || lower.contains("secure") || lower.contains("faillog") {
        "auth".into()
    } else if lower.contains("kern") || lower.contains("dmesg") {
        "kernel".into()
    } else if lower.contains("syslog") || lower.contains("messages") || lower.contains("boot") {
        "system".into()
    } else if lower.contains("cron") {
        "cron".into()
    } else if lower.contains("mail") {
        "mail".into()
    } else if lower.contains("dpkg") || lower.contains("yum") || lower.contains("apt") {
        "package".into()
    } else if lower.contains("nginx") || lower.contains("apache") || lower.contains("httpd") {
        "web".into()
    } else {
        "application".into()
    }
}

#[tauri::command]
pub async fn discover_log_sources(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<LogSourcesResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;
    let client = connection.read().await;

    let mut sources: Vec<LogSource> = Vec::new();

    const FILE_CMD: &str = concat!(
        "find /var/log -maxdepth 3 -type f \\( ",
        "-name '*.log' -o -name '*.log.*' -o ",
        "-name 'syslog' -o -name 'syslog.*' -o ",
        "-name 'messages' -o -name 'messages.*' -o ",
        "-name 'auth.log' -o -name 'auth.log.*' -o ",
        "-name 'secure' -o -name 'secure.*' -o ",
        "-name 'kern.log' -o -name 'daemon.log' -o ",
        "-name 'dmesg' -o -name 'mail.log' -o ",
        "-name 'cron' -o -name 'cron.log' -o ",
        "-name 'boot.log' -o -name 'dpkg.log' -o ",
        "-name 'yum.log' -o -name 'alternatives.log' ",
        "\\) -readable 2>/dev/null | head -80"
    );
    const JOURNAL_CMD: &str = "systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | head -30";
    const DOCKER_CMD: &str =
        r#"docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | head -20"#;

    // Run the three independent discovery commands concurrently — previously
    // they ran sequentially, paying one SSH round-trip per stage.
    let (files, journals, dockers) = tokio::join!(
        client.execute_command(FILE_CMD),
        client.execute_command(JOURNAL_CMD),
        client.execute_command(DOCKER_CMD),
    );

    if let Ok(output) = files {
        for line in output.lines() {
            let path = line.trim().to_string();
            if path.is_empty() {
                continue;
            }
            let name = path.rsplit('/').next().unwrap_or(&path).to_string();
            let category = categorize_log_file(&name);
            sources.push(LogSource {
                id: format!("file:{}", path),
                name,
                source_type: LogSourceKind::File,
                path,
                category,
                size_human: None,
            });
        }
    }

    // `du -h` depends on the file-find output, so it still has to run serially
    // after the parallel phase. One extra round-trip instead of three.
    if !sources.is_empty() {
        let file_paths: Vec<String> = sources
            .iter()
            .filter(|s| s.source_type == LogSourceKind::File)
            .map(|s| sh_quote(&s.path))
            .collect();

        if !file_paths.is_empty() {
            let size_cmd = format!("du -h {} 2>/dev/null", file_paths.join(" "));
            if let Ok(output) = client.execute_command(&size_cmd).await {
                for line in output.lines() {
                    let parts: Vec<&str> = line.trim().split('\t').collect();
                    if parts.len() >= 2 {
                        let size = parts[0].trim();
                        let path = parts[1].trim();
                        if let Some(src) = sources.iter_mut().find(|s| s.path == path) {
                            src.size_human = Some(size.to_string());
            }
    }
            }
        }
    }

    if let Ok(output) = journals {
        for line in output.lines() {
            let unit = line.trim().to_string();
            if unit.is_empty() || unit.starts_with("UNIT") {
                continue;
            }
            let name = unit.strip_suffix(".service").unwrap_or(&unit).to_string();
            sources.push(LogSource {
                id: format!("journal:{}", unit),
                name,
                source_type: LogSourceKind::Journal,
                path: unit,
                category: "service".to_string(),
                size_human: None,
            });
        }
    }

    if let Ok(output) = dockers
        && !output.contains("command not found")
        && !output.contains("Cannot connect")
    {
            for line in output.lines() {
                let parts: Vec<&str> = line.trim().splitn(2, '\t').collect();
                if parts.is_empty() || parts[0].is_empty() {
                    continue;
                }
                let container = parts[0].to_string();
                let status = parts.get(1).map(|s| s.to_string());
                sources.push(LogSource {
                    id: format!("docker:{}", container),
                    name: container.clone(),
                    source_type: LogSourceKind::Docker,
                    path: container,
                    category: "container".to_string(),
                    size_human: status,
                });
            }
        }
    }

    sources.sort_by(|a, b| {
        let type_order = |t: LogSourceKind| match t {
            LogSourceKind::File => 0,
            LogSourceKind::Journal => 1,
            LogSourceKind::Docker => 2,
        };
        type_order(a.source_type)
            .cmp(&type_order(b.source_type))
            .then(a.category.cmp(&b.category))
            .then(a.name.cmp(&b.name))
    });

    Ok(LogSourcesResponse {
        success: true,
        sources,
        error: None,
    })
}

#[tauri::command]
pub async fn read_log(
    connection_id: String,
    source_type: LogSourceKind,
    path: String,
    lines: Option<u32>,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;
    let client = connection.read().await;

    let line_count = lines.unwrap_or(200);

    let cmd = match source_type {
        LogSourceKind::Journal => format!(
            "journalctl -u {} -n {} --no-pager 2>/dev/null",
            sh_quote(&path),
            line_count
        ),
        LogSourceKind::Docker => {
            format!("docker logs --tail {} {} 2>&1", line_count, sh_quote(&path))
        }
        LogSourceKind::File => {
            format!("tail -n {} {} 2>/dev/null", line_count, sh_quote(&path))
        }
    };

    match client.execute_command(&cmd).await {
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

#[tauri::command]
pub async fn search_log(
    connection_id: String,
    source_type: LogSourceKind,
    path: String,
    pattern: String,
    is_regex: Option<bool>,
    max_results: Option<u32>,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;
    let client = connection.read().await;

    let limit = max_results.unwrap_or(500);
    let q_pattern = sh_quote(&pattern);
    let q_path = sh_quote(&path);
    let grep_flag = if is_regex.unwrap_or(false) {
        "-nE"
    } else {
        "-nF"
    };

    let cmd = match source_type {
        LogSourceKind::Journal => format!(
            "journalctl -u {} --no-pager 2>/dev/null | grep {} -i {} | tail -n {}",
            q_path, grep_flag, q_pattern, limit
        ),
        LogSourceKind::Docker => format!(
            "docker logs {} 2>&1 | grep {} -i {} | tail -n {}",
            q_path, grep_flag, q_pattern, limit
        ),
        LogSourceKind::File => format!(
            "grep {} -i {} {} 2>/dev/null | tail -n {}",
            grep_flag, q_pattern, q_path, limit
        ),
    };

    match client.execute_command(&cmd).await {
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
