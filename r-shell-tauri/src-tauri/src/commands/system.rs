//! System-level metrics scraped from the remote shell.

use r_shell_core::connection_manager::ConnectionManager;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::State;

#[derive(Debug, Serialize, Deserialize)]
pub struct MemoryStats {
    pub total: u64,
    pub used: u64,
    pub free: u64,
    pub available: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DiskStats {
    pub total: String,
    pub used: String,
    pub available: String,
    pub use_percent: f64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SystemStats {
    pub cpu_percent: f64,
    pub memory: MemoryStats,
    pub swap: MemoryStats,
    pub disk: DiskStats,
    pub uptime: String,
    pub load_average: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SystemdServiceInfo {
    pub name: String,
    pub load: String,
    pub active: String,
    pub sub: String,
    pub description: String,
}

#[derive(Debug, Serialize)]
pub struct SystemdServicesResponse {
    pub success: bool,
    pub systemd_available: bool,
    pub services: Vec<SystemdServiceInfo>,
    pub error: Option<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct UfwStatusResponse {
    pub success: bool,
    pub available: bool,
    pub enabled: bool,
    pub has_extra_open_ports: bool,
    pub extra_open_rules: Vec<String>,
    pub status: String,
    pub status_text: String,
    pub error: Option<String>,
}

const SYSTEMD_UNAVAILABLE_MARKER: &str = "__R_SHELL_SYSTEMD_UNAVAILABLE__";
const UFW_UNAVAILABLE_MARKER: &str = "__R_SHELL_UFW_UNAVAILABLE__";

#[tauri::command]
pub async fn get_system_stats(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<SystemStats, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let cpu_cmd = "top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1}'";
    let cpu_percent = client
        .execute_command(cpu_cmd)
        .await
        .ok()
        .and_then(|s| s.trim().parse::<f64>().ok())
        .unwrap_or(0.0);

    let mem_cmd = "free -m | awk 'NR==2{printf \"%s %s %s %s\", $2,$3,$4,$7}'";
    let mem_output = client.execute_command(mem_cmd).await.unwrap_or_default();
    let mem_parts: Vec<&str> = mem_output.split_whitespace().collect();
    let memory = MemoryStats {
        total: mem_parts.first().and_then(|s| s.parse().ok()).unwrap_or(0),
        used: mem_parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0),
        free: mem_parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0),
        available: mem_parts.get(3).and_then(|s| s.parse().ok()).unwrap_or(0),
    };

    let swap_cmd = "free -m | awk 'NR==3{printf \"%s %s %s\", $2,$3,$4}'";
    let swap_output = client.execute_command(swap_cmd).await.unwrap_or_default();
    let swap_parts: Vec<&str> = swap_output.split_whitespace().collect();
    let swap = MemoryStats {
        total: swap_parts.first().and_then(|s| s.parse().ok()).unwrap_or(0),
        used: swap_parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0),
        free: swap_parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0),
        available: 0,
    };

    let disk_cmd = "df -h / | awk 'NR==2{printf \"%s %s %s %s\", $2,$3,$4,$5}'";
    let disk_output = client.execute_command(disk_cmd).await.unwrap_or_default();
    let disk_parts: Vec<&str> = disk_output.split_whitespace().collect();
    let disk = DiskStats {
        total: disk_parts.first().unwrap_or(&"0").to_string(),
        used: disk_parts.get(1).unwrap_or(&"0").to_string(),
        available: disk_parts.get(2).unwrap_or(&"0").to_string(),
        use_percent: disk_parts
            .get(3)
            .and_then(|s| s.trim_end_matches('%').parse().ok())
            .unwrap_or(0.0),
    };

    let uptime_cmd = "uptime -p 2>/dev/null || uptime | awk '{print $3\" \"$4}'";
    let uptime = client
        .execute_command(uptime_cmd)
        .await
        .unwrap_or_else(|_| "Unknown".to_string())
        .trim()
        .to_string();

    let load_cmd = "uptime | awk -F'load average:' '{print $2}' | xargs";
    let load_average = client
        .execute_command(load_cmd)
        .await
        .ok()
        .map(|s| s.trim().to_string());

    Ok(SystemStats {
        cpu_percent,
        memory,
        swap,
        disk,
        uptime,
        load_average,
    })
}

#[tauri::command]
pub async fn get_systemd_services(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<SystemdServicesResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let command = format!(
        "if command -v systemctl >/dev/null 2>&1; then \
            systemctl list-units --type=service --all --no-pager --no-legend --plain 2>&1 | head -80; \
         else echo {SYSTEMD_UNAVAILABLE_MARKER}; fi"
    );

    let output = client
        .execute_command(&command)
        .await
        .map_err(|e| e.to_string())?;
    let (systemd_available, services, error) = parse_systemd_services_output(&output);

    Ok(SystemdServicesResponse {
        success: true,
        systemd_available,
        services,
        error,
    })
}

#[tauri::command]
pub async fn get_ufw_status(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<UfwStatusResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let command = format!(
        "if command -v ufw >/dev/null 2>&1; then \
            ufw status 2>&1 | head -80; \
         else echo {UFW_UNAVAILABLE_MARKER}; fi"
    );

    let output = client
        .execute_command(&command)
        .await
        .map_err(|e| e.to_string())?;

    Ok(parse_ufw_status_output(&output))
}

fn parse_systemd_services_output(output: &str) -> (bool, Vec<SystemdServiceInfo>, Option<String>) {
    let trimmed = output.trim();
    if trimmed == SYSTEMD_UNAVAILABLE_MARKER {
        return (false, Vec::new(), None);
    }

    let lower = trimmed.to_lowercase();
    if lower.contains("system has not been booted with systemd")
        || lower.contains("failed to connect to bus")
    {
        return (
            false,
            Vec::new(),
            trimmed.lines().next().map(|line| line.trim().to_string()),
        );
    }

    let services = output
        .lines()
        .filter_map(parse_systemd_service_line)
        .collect();

    (true, services, None)
}

fn parse_systemd_service_line(line: &str) -> Option<SystemdServiceInfo> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 4 || !parts[0].ends_with(".service") {
        return None;
    }

    Some(SystemdServiceInfo {
        name: parts[0].to_string(),
        load: parts[1].to_string(),
        active: parts[2].to_string(),
        sub: parts[3].to_string(),
        description: parts.get(4..).unwrap_or(&[]).join(" "),
    })
}

fn parse_ufw_status_output(output: &str) -> UfwStatusResponse {
    let status_text = output
        .lines()
        .find_map(|line| {
            let trimmed = line.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        })
        .unwrap_or_else(|| "Unknown".to_string());

    if status_text == UFW_UNAVAILABLE_MARKER {
        return UfwStatusResponse {
            success: true,
            available: false,
            enabled: false,
            has_extra_open_ports: false,
            extra_open_rules: Vec::new(),
            status: "unavailable".to_string(),
            status_text: "UFW not installed".to_string(),
            error: None,
        };
    }

    let lower = status_text.to_lowercase();
    if lower.contains("inactive") {
        return UfwStatusResponse {
            success: true,
            available: true,
            enabled: false,
            has_extra_open_ports: false,
            extra_open_rules: Vec::new(),
            status: "inactive".to_string(),
            status_text,
            error: None,
        };
    }

    if lower.contains("active") {
        let extra_open_rules = collect_extra_ufw_open_rules(output);
        let has_extra_open_ports = !extra_open_rules.is_empty();

        return UfwStatusResponse {
            success: true,
            available: true,
            enabled: true,
            has_extra_open_ports,
            extra_open_rules,
            status: "active".to_string(),
            status_text,
            error: None,
        };
    }

    let error = if lower.contains("permission")
        || lower.contains("need to be root")
        || lower.contains("must be root")
    {
        Some(status_text.clone())
    } else {
        None
    };

    UfwStatusResponse {
        success: true,
        available: true,
        enabled: false,
        has_extra_open_ports: false,
        extra_open_rules: Vec::new(),
        status: "unknown".to_string(),
        status_text,
        error,
    }
}

fn collect_extra_ufw_open_rules(output: &str) -> Vec<String> {
    output
        .lines()
        .filter_map(parse_ufw_open_rule)
        .filter(|rule| !is_allowed_ufw_rule(rule))
        .map(str::to_string)
        .collect()
}

fn parse_ufw_open_rule(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    if trimmed.is_empty()
        || trimmed.starts_with("Status:")
        || trimmed.starts_with("To ")
        || trimmed.starts_with("--")
    {
        return None;
    }

    let action_index = trimmed.find(" ALLOW").or_else(|| trimmed.find(" LIMIT"))?;
    let rule = trimmed[..action_index].trim();
    (!rule.is_empty()).then_some(rule)
}

fn is_allowed_ufw_rule(rule: &str) -> bool {
    let normalized = normalize_ufw_rule(rule);
    let known_allowed_services = [
        "http",
        "https",
        "ssh",
        "openssh",
        "www",
        "www full",
        "www secure",
        "apache",
        "apache full",
        "apache secure",
        "nginx http",
        "nginx https",
        "nginx full",
    ];

    if known_allowed_services.contains(&normalized.as_str()) {
        return true;
    }

    let Some(port_spec) = normalized.split_whitespace().next() else {
        return false;
    };
    let port_spec = port_spec.split('/').next().unwrap_or(port_spec);

    port_spec
        .split(',')
        .all(|port| matches!(port, "22" | "80" | "443"))
}

fn normalize_ufw_rule(rule: &str) -> String {
    rule.replace("(v6)", "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_systemd_service_rows() {
        let output = "\
ssh.service loaded active running OpenBSD Secure Shell server\n\
ufw.service loaded inactive dead Uncomplicated firewall\n";

        let (available, services, error) = parse_systemd_services_output(output);

        assert!(available);
        assert!(error.is_none());
        assert_eq!(
            services,
            vec![
                SystemdServiceInfo {
                    name: "ssh.service".to_string(),
                    load: "loaded".to_string(),
                    active: "active".to_string(),
                    sub: "running".to_string(),
                    description: "OpenBSD Secure Shell server".to_string(),
                },
                SystemdServiceInfo {
                    name: "ufw.service".to_string(),
                    load: "loaded".to_string(),
                    active: "inactive".to_string(),
                    sub: "dead".to_string(),
                    description: "Uncomplicated firewall".to_string(),
                },
            ],
        );
    }

    #[test]
    fn detects_systemd_unavailable_errors() {
        let (available, services, error) = parse_systemd_services_output(
            "System has not been booted with systemd as init system (PID 1). Can't operate.",
        );

        assert!(!available);
        assert!(services.is_empty());
        assert!(error.is_some());
    }

    #[test]
    fn parses_ufw_active_and_inactive_states() {
        let active = parse_ufw_status_output(
            "\
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80,443/tcp                 ALLOW       Anywhere
OpenSSH (v6)               ALLOW       Anywhere (v6)
",
        );

        assert_eq!(active.status, "active");
        assert!(active.enabled);
        assert!(!active.has_extra_open_ports);
        assert!(active.extra_open_rules.is_empty());

        let inactive = parse_ufw_status_output("Status: inactive\n");
        assert_eq!(inactive.status, "inactive");
        assert!(!inactive.enabled);
    }

    #[test]
    fn flags_extra_ufw_open_rules() {
        let status = parse_ufw_status_output(
            "\
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
8080/tcp                   ALLOW       Anywhere
Nginx Full                 ALLOW       Anywhere
Postfix                    ALLOW       Anywhere
",
        );

        assert!(status.enabled);
        assert!(status.has_extra_open_ports);
        assert_eq!(
            status.extra_open_rules,
            vec!["8080/tcp".to_string(), "Postfix".to_string()]
        );
    }

    #[test]
    fn parses_ufw_unavailable_marker() {
        let status = parse_ufw_status_output(UFW_UNAVAILABLE_MARKER);

        assert!(status.success);
        assert!(!status.available);
        assert_eq!(status.status, "unavailable");
    }
}
