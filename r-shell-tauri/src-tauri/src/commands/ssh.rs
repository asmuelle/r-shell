//! SSH lifecycle commands: connect / cancel / disconnect / execute / tab-complete,
//! plus the interactive-command transform helpers and list_connections.

use r_shell_core::connection_manager::ConnectionManager;
use r_shell_core::ssh::shell::quote as sh_quote;
use r_shell_core::ssh::{AuthMethod, SshConfig};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::State;

// TabCompletionResponse below needs Serialize; ConnectRequest no longer does.

use super::{
    AuthMethodTag, CommandResponse, normalize_optional_non_blank, normalize_optional_trimmed,
    normalize_required_field,
};

#[derive(Deserialize)]
pub struct ConnectRequest {
    pub connection_id: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: AuthMethodTag,
    pub password: Option<String>,
    pub key_path: Option<String>,
    pub passphrase: Option<String>,
}

impl std::fmt::Debug for ConnectRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectRequest")
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
pub async fn ssh_connect(
    request: ConnectRequest,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let host = normalize_required_field(request.host, "Host")?;
    let username = normalize_required_field(request.username, "Username")?;
    let auth_method = match request.auth_method {
        AuthMethodTag::Password => AuthMethod::Password {
            password: request.password.ok_or("Password required")?,
        },
        AuthMethodTag::PublicKey => AuthMethod::PublicKey {
            key_path: normalize_optional_trimmed(request.key_path).ok_or("Key path required")?,
            passphrase: normalize_optional_non_blank(request.passphrase),
        },
    };

    let config = SshConfig {
        host,
        port: request.port,
        username,
        auth_method,
    };

    match state
        .create_connection(request.connection_id.clone(), config)
        .await
    {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some(format!("Connected: {}", request.connection_id)),
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
pub async fn ssh_cancel_connect(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    if state.cancel_pending_connection(&connection_id).await {
        Ok(CommandResponse {
            success: true,
            output: Some("Connection cancelled".to_string()),
            error: None,
        })
    } else {
        Ok(CommandResponse {
            success: false,
            output: None,
            error: Some("No pending connection to cancel".to_string()),
        })
    }
}

#[tauri::command]
pub async fn ssh_disconnect(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    match state.close_connection(&connection_id).await {
        Ok(_) => Ok(CommandResponse {
            success: true,
            output: Some("Disconnected".to_string()),
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
pub async fn ssh_execute_command(
    connection_id: String,
    command: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<CommandResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let transformed_command = transform_interactive_command(&command);

    match client.execute_command_full(&transformed_command).await {
        Ok(out) if out.is_success() => Ok(CommandResponse {
            success: true,
            output: Some(out.combined()),
            error: None,
        }),
        Ok(out) => {
            let combined = out.combined();
            let hint = if is_interactive_command(&command) {
                format!(
                    "\n\nNote: Interactive commands like '{}' may not work in this terminal. Try using batch mode alternatives.",
                    get_command_name(&command)
                )
            } else {
                String::new()
            };
            let message = format!(
                "{}{}\n(exit code: {})",
                combined,
                hint,
                out.exit_code
                    .map(|c| c.to_string())
                    .unwrap_or_else(|| "unknown".to_string())
            );
            Ok(CommandResponse {
                success: false,
                output: Some(combined),
                error: Some(message),
            })
        }
        Err(e) => Ok(CommandResponse {
            success: false,
            output: None,
            error: Some(e.to_string()),
        }),
    }
}

// ---------------------------------------------------------------------------
// Interactive-command transform helpers
// ---------------------------------------------------------------------------

fn transform_interactive_command(command: &str) -> String {
    let cmd = command.trim();
    if cmd == "top" || cmd.starts_with("top ") {
        return format!("{} -bn1", cmd);
    }
    if cmd == "htop" || cmd.starts_with("htop ") {
        return "top -bn1".to_string();
    }
    command.to_string()
}

fn is_interactive_command(command: &str) -> bool {
    let cmd_name = get_command_name(command);
    matches!(
        cmd_name.as_str(),
        "top"
            | "htop"
            | "vim"
            | "vi"
            | "nano"
            | "emacs"
            | "less"
            | "more"
            | "man"
            | "tmux"
            | "screen"
    )
}

fn get_command_name(command: &str) -> String {
    command.split_whitespace().next().unwrap_or("").to_string()
}

// ---------------------------------------------------------------------------
// Tab completion
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct TabCompletionResponse {
    pub success: bool,
    pub completions: Vec<String>,
    pub common_prefix: Option<String>,
    pub error: Option<String>,
}

#[tauri::command]
pub async fn ssh_tab_complete(
    connection_id: String,
    input: String,
    cursor_position: usize,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<TabCompletionResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let text_before_cursor = &input[..cursor_position.min(input.len())];
    let words: Vec<&str> = text_before_cursor.split_whitespace().collect();
    let word_to_complete = words.last().copied().unwrap_or("");
    let is_first_word = words.len() <= 1;

    // `word_to_complete` is arbitrary user input — must be shell-quoted.
    // We filter the output in Rust too (see `.starts_with` below), so quoting
    // here does not hide legitimate matches.
    let quoted_word = sh_quote(word_to_complete);
    let dir_arg = if word_to_complete.is_empty() {
        sh_quote(".")
    } else {
        quoted_word.clone()
    };
    let completion_cmd = if is_first_word {
        format!("compgen -c {} 2>/dev/null || echo", quoted_word)
    } else {
        format!(
            "compgen -f {} 2>/dev/null || ls -1ap {} 2>/dev/null",
            quoted_word, dir_arg
        )
    };

    match client.execute_command(&completion_cmd).await {
        Ok(output) => {
            let completions: Vec<String> = output
                .lines()
                .filter(|s| !s.is_empty() && s.starts_with(word_to_complete))
                .map(|s| s.trim().to_string())
                .take(50)
                .collect();

            let common_prefix = if completions.len() > 1 {
                find_common_prefix(&completions)
            } else {
                None
            };

            Ok(TabCompletionResponse {
                success: true,
                completions,
                common_prefix,
                error: None,
            })
        }
        Err(e) => Ok(TabCompletionResponse {
            success: false,
            completions: Vec::new(),
            common_prefix: None,
            error: Some(e.to_string()),
        }),
    }
}

fn find_common_prefix(strings: &[String]) -> Option<String> {
    if strings.is_empty() {
        return None;
    }
    if strings.len() == 1 {
        return Some(strings[0].clone());
    }
    let first = &strings[0];
    let mut prefix = String::new();
    for (i, ch) in first.chars().enumerate() {
        if strings.iter().all(|s| s.chars().nth(i) == Some(ch)) {
            prefix.push(ch);
        } else {
            break;
        }
    }
    if prefix.is_empty() || prefix == strings[0] {
        None
    } else {
        Some(prefix)
    }
}

#[tauri::command]
pub async fn list_connections(
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<Vec<String>, String> {
    Ok(state.list_connections().await)
}
