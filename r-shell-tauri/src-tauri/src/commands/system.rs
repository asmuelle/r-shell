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
