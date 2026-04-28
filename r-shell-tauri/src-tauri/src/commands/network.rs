//! Remote network telemetry: interfaces, active connections, bandwidth,
//! latency, and disk usage.

use r_shell_core::connection_manager::ConnectionManager;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::State;

#[derive(Debug, Serialize, Deserialize)]
pub struct NetworkInterface {
    pub name: String,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_packets: u64,
    pub tx_packets: u64,
}

#[derive(Debug, Serialize)]
pub struct NetworkStatsResponse {
    pub success: bool,
    pub interfaces: Vec<NetworkInterface>,
    pub error: Option<String>,
}

#[tauri::command]
pub async fn get_network_stats(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<NetworkStatsResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let command = r#"
for iface in /sys/class/net/*; do
    name=$(basename $iface)
    if [ "$name" != "lo" ]; then
        rx_bytes=$(cat $iface/statistics/rx_bytes 2>/dev/null || echo 0)
        tx_bytes=$(cat $iface/statistics/tx_bytes 2>/dev/null || echo 0)
        rx_packets=$(cat $iface/statistics/rx_packets 2>/dev/null || echo 0)
        tx_packets=$(cat $iface/statistics/tx_packets 2>/dev/null || echo 0)
        echo "$name,$rx_bytes,$tx_bytes,$rx_packets,$tx_packets"
    fi
done
"#;

    match client.execute_command(command).await {
        Ok(output) => {
            let mut interfaces = Vec::new();
            for line in output.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                let parts: Vec<&str> = line.split(',').collect();
                if parts.len() == 5
                    && let (Ok(rx_bytes), Ok(tx_bytes), Ok(rx_packets), Ok(tx_packets)) = (
                        parts[1].parse::<u64>(),
                        parts[2].parse::<u64>(),
                        parts[3].parse::<u64>(),
                        parts[4].parse::<u64>(),
                    )
                {
                    interfaces.push(NetworkInterface {
                        name: parts[0].to_string(),
                        rx_bytes,
                        tx_bytes,
                        rx_packets,
                        tx_packets,
                    });
                }
            }
            Ok(NetworkStatsResponse {
                success: true,
                interfaces,
                error: None,
            })
        }
        Err(e) => Ok(NetworkStatsResponse {
            success: false,
            interfaces: Vec::new(),
            error: Some(e.to_string()),
        }),
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct NetworkConnection {
    pub protocol: String,
    pub local_address: String,
    pub remote_address: String,
    pub state: String,
    pub pid_program: String,
}

#[derive(Debug, Serialize)]
pub struct ConnectionsResponse {
    pub success: bool,
    pub connections: Vec<NetworkConnection>,
    pub error: Option<String>,
}

#[tauri::command]
pub async fn get_active_connections(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<ConnectionsResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = "ss -tunp 2>/dev/null | tail -n +2 | head -50";

    match client.execute_command(command).await {
        Ok(output) => {
            let mut connections = Vec::new();
            for line in output.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 5 {
                    let protocol = parts[0].to_string();
                    let local_address = parts[4].to_string();
                    let remote_address = parts[5].to_string();
                    let state = if parts.len() > 1 && parts[1] != "0" {
                        "ESTAB".to_string()
                    } else {
                        parts.get(1).unwrap_or(&"").to_string()
                    };
                    let pid_program = parts.get(6).unwrap_or(&"").to_string();

                    connections.push(NetworkConnection {
                        protocol,
                        local_address,
                        remote_address,
                        state,
                        pid_program,
                    });
                }
            }
            Ok(ConnectionsResponse {
                success: true,
                connections,
                error: None,
            })
        }
        Err(e) => Ok(ConnectionsResponse {
            success: false,
            connections: Vec::new(),
            error: Some(e.to_string()),
        }),
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct NetworkBandwidth {
    pub interface: String,
    pub rx_bytes_per_sec: f64,
    pub tx_bytes_per_sec: f64,
}

#[derive(Debug, Serialize)]
pub struct BandwidthResponse {
    pub success: bool,
    pub bandwidth: Vec<NetworkBandwidth>,
    pub error: Option<String>,
}

#[tauri::command]
pub async fn get_network_bandwidth(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<BandwidthResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let command = r#"
iface_list=""
for iface in /sys/class/net/*; do
    name=$(basename $iface)
    if [ "$name" != "lo" ]; then
        iface_list="$iface_list $name"
    fi
done

for iface in $iface_list; do
    rx1=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
    tx1=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    echo "$iface,$rx1,$tx1"
done
sleep 1
for iface in $iface_list; do
    rx2=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
    tx2=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    echo "$iface,$rx2,$tx2"
done
"#;

    match client.execute_command(command).await {
        Ok(output) => {
            let lines: Vec<&str> = output.lines().collect();
            let mut bandwidth = Vec::new();
            let mid = lines.len() / 2;
            let before = &lines[0..mid];
            let after = &lines[mid..];

            for (before_line, after_line) in before.iter().zip(after.iter()) {
                let before_parts: Vec<&str> = before_line.split(',').collect();
                let after_parts: Vec<&str> = after_line.split(',').collect();

                if before_parts.len() == 3
                    && after_parts.len() == 3
                    && before_parts[0] == after_parts[0]
                    && let (Ok(rx1), Ok(tx1), Ok(rx2), Ok(tx2)) = (
                        before_parts[1].parse::<f64>(),
                        before_parts[2].parse::<f64>(),
                        after_parts[1].parse::<f64>(),
                        after_parts[2].parse::<f64>(),
                    )
                {
                    bandwidth.push(NetworkBandwidth {
                        interface: before_parts[0].to_string(),
                        rx_bytes_per_sec: rx2 - rx1,
                        tx_bytes_per_sec: tx2 - tx1,
                    });
                }
            }
            Ok(BandwidthResponse {
                success: true,
                bandwidth,
                error: None,
            })
        }
        Err(e) => Ok(BandwidthResponse {
            success: false,
            bandwidth: Vec::new(),
            error: Some(e.to_string()),
        }),
    }
}

#[derive(Debug, Serialize)]
pub struct LatencyResponse {
    pub success: bool,
    pub latency_ms: Option<f64>,
    pub error: Option<String>,
}

#[tauri::command]
pub async fn get_network_latency(
    connection_id: String,
    _target: Option<String>,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<LatencyResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let start = std::time::Instant::now();

    match client.execute_command("echo ping").await {
        Ok(output) => {
            let duration = start.elapsed();
            let latency_ms = duration.as_secs_f64() * 1000.0;
            if output.trim() == "ping" {
                Ok(LatencyResponse {
                    success: true,
                    latency_ms: Some(latency_ms),
                    error: None,
                })
            } else {
                Ok(LatencyResponse {
                    success: false,
                    latency_ms: None,
                    error: Some("Command verification failed".to_string()),
                })
            }
        }
        Err(e) => Ok(LatencyResponse {
            success: false,
            latency_ms: None,
            error: Some(format!("SSH connection error: {}", e)),
        }),
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DiskInfo {
    pub filesystem: String,
    pub path: String,
    pub total: String,
    pub used: String,
    pub available: String,
    pub usage: u32,
}

#[derive(Debug, Serialize)]
pub struct DiskUsageResponse {
    pub success: bool,
    pub disks: Vec<DiskInfo>,
    pub error: Option<String>,
}

#[tauri::command]
pub async fn get_disk_usage(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<DiskUsageResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;
    let command = "df -hT | grep -v 'tmpfs\\|devtmpfs\\|Filesystem' | awk '{print $1\"|\"$7\"|\"$3\"|\"$4\"|\"$5\"|\"$6}' | head -10";

    match client.execute_command(command).await {
        Ok(output) => {
            let mut disks = Vec::new();
            for line in output.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                let parts: Vec<&str> = line.split('|').collect();
                if parts.len() == 6 {
                    let usage_str = parts[5].trim_end_matches('%');
                    let usage = usage_str.parse::<u32>().unwrap_or(0);
                    disks.push(DiskInfo {
                        filesystem: parts[0].to_string(),
                        path: parts[1].to_string(),
                        total: parts[2].to_string(),
                        used: parts[3].to_string(),
                        available: parts[4].to_string(),
                        usage,
                    });
                }
            }
            Ok(DiskUsageResponse {
                success: true,
                disks,
                error: None,
            })
        }
        Err(e) => Ok(DiskUsageResponse {
            success: false,
            disks: Vec::new(),
            error: Some(e.to_string()),
        }),
    }
}
