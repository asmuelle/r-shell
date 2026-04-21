//! Remote GPU detection and live stats (NVIDIA via nvidia-smi, AMD via
//! rocm-smi JSON or sysfs fallback).

use crate::connection_manager::ConnectionManager;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::State;

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum GpuVendor {
    Nvidia,
    Amd,
    Unknown,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct GpuInfo {
    pub index: u32,
    pub name: String,
    pub vendor: GpuVendor,
    pub driver_version: Option<String>,
    pub cuda_version: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct GpuStats {
    pub index: u32,
    pub name: String,
    pub vendor: GpuVendor,
    pub utilization: f64,
    pub memory_used: u64,
    pub memory_total: u64,
    pub memory_percent: f64,
    pub temperature: Option<f64>,
    pub power_draw: Option<f64>,
    pub power_limit: Option<f64>,
    pub fan_speed: Option<f64>,
    pub encoder_util: Option<f64>,
    pub decoder_util: Option<f64>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct GpuDetectionResult {
    pub available: bool,
    pub vendor: GpuVendor,
    pub gpus: Vec<GpuInfo>,
    pub detection_method: String,
}

#[derive(Debug, Serialize)]
pub struct GpuStatsResponse {
    pub success: bool,
    pub gpus: Vec<GpuStats>,
    pub error: Option<String>,
}

#[tauri::command]
pub async fn detect_gpu(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<GpuDetectionResult, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let nvidia_check = client
        .execute_command("which nvidia-smi 2>/dev/null && nvidia-smi --query-gpu=index,name,driver_version --format=csv,noheader 2>/dev/null")
        .await;

    if let Ok(output) = nvidia_check {
        let output = output.trim();
        if !output.is_empty() && !output.contains("not found") && !output.contains("No such file") {
            let mut gpus = Vec::new();
            for line in output.lines() {
                if line.contains("nvidia-smi") || line.trim().is_empty() {
                    continue;
                }
                let parts: Vec<&str> = line.split(',').map(|s| s.trim()).collect();
                if parts.len() >= 2 {
                    let index = parts[0].parse::<u32>().unwrap_or(0);
                    let name = parts[1].to_string();
                    let driver_version = parts.get(2).map(|s| s.to_string());

                    let cuda_version = client
                        .execute_command("nvidia-smi | sed -n 's/.*CUDA Version: \\([0-9.]*\\).*/\\1/p' | head -1")
                        .await
                        .ok()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty());

                    gpus.push(GpuInfo {
                        index,
                        name,
                        vendor: GpuVendor::Nvidia,
                        driver_version,
                        cuda_version,
                    });
                }
            }
            if !gpus.is_empty() {
                return Ok(GpuDetectionResult {
                    available: true,
                    vendor: GpuVendor::Nvidia,
                    gpus,
                    detection_method: "nvidia-smi".to_string(),
                });
            }
        }
    }

    let amd_rocm_check = client
        .execute_command(
            "which rocm-smi 2>/dev/null && rocm-smi --showid --showproductname 2>/dev/null",
        )
        .await;

    if let Ok(output) = amd_rocm_check {
        let output = output.trim();
        if !output.is_empty() && !output.contains("not found") && output.contains("GPU") {
            let mut gpus = Vec::new();
            let mut current_index = 0u32;
            let mut current_name = String::new();

            for line in output.lines() {
                if line.contains("rocm-smi") || line.trim().is_empty() || line.starts_with("=") {
                    continue;
                }
                if line.contains("GPU[") {
                    if let Some(start) = line.find("GPU[") {
                        if let Some(end) = line[start..].find(']') {
                            let idx_str = &line[start + 4..start + end];
                            current_index = idx_str.parse::<u32>().unwrap_or(current_index);
                        }
                    }
                }
                if line.contains("Card series:") || line.contains("Card model:") {
                    if let Some(name) = line.split(':').nth(1) {
                        current_name = name.trim().to_string();
                    }
                }
            }

            if current_name.is_empty() {
                current_name = "AMD GPU".to_string();
            }

            gpus.push(GpuInfo {
                index: current_index,
                name: current_name,
                vendor: GpuVendor::Amd,
                driver_version: None,
                cuda_version: None,
            });

            if !gpus.is_empty() {
                return Ok(GpuDetectionResult {
                    available: true,
                    vendor: GpuVendor::Amd,
                    gpus,
                    detection_method: "rocm-smi".to_string(),
                });
            }
        }
    }

    let amd_sysfs_check = client
        .execute_command("ls /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -1")
        .await;

    if let Ok(output) = amd_sysfs_check {
        let output = output.trim();
        if !output.is_empty() && output.contains("gpu_busy_percent") {
            let card_count = client
                .execute_command(
                    "ls -d /sys/class/drm/card[0-9]*/device/gpu_busy_percent 2>/dev/null | wc -l",
                )
                .await
                .ok()
                .and_then(|s| s.trim().parse::<u32>().ok())
                .unwrap_or(1);

            let gpus: Vec<GpuInfo> = (0..card_count)
                .map(|i| GpuInfo {
                    index: i,
                    name: format!("AMD GPU {}", i),
                    vendor: GpuVendor::Amd,
                    driver_version: None,
                    cuda_version: None,
                })
                .collect();

            return Ok(GpuDetectionResult {
                available: true,
                vendor: GpuVendor::Amd,
                gpus,
                detection_method: "sysfs".to_string(),
            });
        }
    }

    Ok(GpuDetectionResult {
        available: false,
        vendor: GpuVendor::Unknown,
        gpus: Vec::new(),
        detection_method: "none".to_string(),
    })
}

#[tauri::command]
pub async fn get_gpu_stats(
    connection_id: String,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<GpuStatsResponse, String> {
    let connection = state
        .get_connection(&connection_id)
        .await
        .ok_or("Connection not found")?;

    let client = connection.read().await;

    let nvidia_cmd = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,utilization.encoder,utilization.decoder --format=csv,noheader,nounits 2>/dev/null";

    if let Ok(output) = client.execute_command(nvidia_cmd).await {
        let output = output.trim();
        if !output.is_empty() && !output.contains("not found") && !output.contains("Failed") {
            let mut gpus = Vec::new();
            for line in output.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                let parts: Vec<&str> = line.split(',').map(|s| s.trim()).collect();
                if parts.len() >= 5 {
                    let index = parts[0].parse::<u32>().unwrap_or(0);
                    let name = parts[1].to_string();
                    let utilization = parts[2].parse::<f64>().unwrap_or(0.0);
                    let memory_used = parts[3].parse::<u64>().unwrap_or(0);
                    let memory_total = parts[4].parse::<u64>().unwrap_or(1);
                    let memory_percent = if memory_total > 0 {
                        (memory_used as f64 / memory_total as f64) * 100.0
                    } else {
                        0.0
                    };

                    let temperature = parts.get(5).and_then(|s| s.parse::<f64>().ok());
                    let power_draw = parts.get(6).and_then(|s| s.parse::<f64>().ok());
                    let power_limit = parts.get(7).and_then(|s| s.parse::<f64>().ok());
                    let fan_speed = parts.get(8).and_then(|s| s.parse::<f64>().ok());
                    let encoder_util = parts.get(9).and_then(|s| s.parse::<f64>().ok());
                    let decoder_util = parts.get(10).and_then(|s| s.parse::<f64>().ok());

                    gpus.push(GpuStats {
                        index,
                        name,
                        vendor: GpuVendor::Nvidia,
                        utilization,
                        memory_used,
                        memory_total,
                        memory_percent,
                        temperature,
                        power_draw,
                        power_limit,
                        fan_speed,
                        encoder_util,
                        decoder_util,
                    });
                }
            }
            if !gpus.is_empty() {
                return Ok(GpuStatsResponse {
                    success: true,
                    gpus,
                    error: None,
                });
            }
        }
    }

    let amd_rocm_cmd =
        "rocm-smi --showuse --showmeminfo vram --showtemp --showpower --showfan --json 2>/dev/null";

    if let Ok(output) = client.execute_command(amd_rocm_cmd).await {
        let output = output.trim();
        if !output.is_empty() && output.starts_with('{') {
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(output) {
                let mut gpus = Vec::new();
                if let Some(obj) = json.as_object() {
                    for (key, value) in obj {
                        if key.starts_with("card") {
                            let index = key.trim_start_matches("card").parse::<u32>().unwrap_or(0);

                            let utilization = value
                                .get("GPU use (%)")
                                .and_then(|v| v.as_str())
                                .and_then(|s| s.trim_end_matches('%').parse::<f64>().ok())
                                .unwrap_or(0.0);

                            let memory_used = value
                                .get("VRAM Total Used Memory (B)")
                                .and_then(|v| v.as_str())
                                .and_then(|s| s.parse::<u64>().ok())
                                .map(|b| b / (1024 * 1024))
                                .unwrap_or(0);

                            let memory_total = value
                                .get("VRAM Total Memory (B)")
                                .and_then(|v| v.as_str())
                                .and_then(|s| s.parse::<u64>().ok())
                                .map(|b| b / (1024 * 1024))
                                .unwrap_or(1);

                            let memory_percent = if memory_total > 0 {
                                (memory_used as f64 / memory_total as f64) * 100.0
                            } else {
                                0.0
                            };

                            let temperature = value
                                .get("Temperature (Sensor edge) (C)")
                                .and_then(|v| v.as_str())
                                .and_then(|s| s.parse::<f64>().ok());

                            let power_draw = value
                                .get("Average Graphics Package Power (W)")
                                .and_then(|v| v.as_str())
                                .and_then(|s| s.parse::<f64>().ok());

                            let fan_speed = value
                                .get("Fan speed (%)")
                                .and_then(|v| v.as_str())
                                .and_then(|s| s.trim_end_matches('%').parse::<f64>().ok());

                            gpus.push(GpuStats {
                                index,
                                name: format!("AMD GPU {}", index),
                                vendor: GpuVendor::Amd,
                                utilization,
                                memory_used,
                                memory_total,
                                memory_percent,
                                temperature,
                                power_draw,
                                power_limit: None,
                                fan_speed,
                                encoder_util: None,
                                decoder_util: None,
                            });
                        }
                    }
                }
                if !gpus.is_empty() {
                    return Ok(GpuStatsResponse {
                        success: true,
                        gpus,
                        error: None,
                    });
                }
            }
        }
    }

    let amd_sysfs_cmd = r#"
for card in /sys/class/drm/card[0-9]*; do
    if [ -f "$card/device/gpu_busy_percent" ]; then
        idx=$(basename $card | sed 's/card//')
        util=$(cat "$card/device/gpu_busy_percent" 2>/dev/null || echo "0")
        vram_used=$(cat "$card/device/mem_info_vram_used" 2>/dev/null || echo "0")
        vram_total=$(cat "$card/device/mem_info_vram_total" 2>/dev/null || echo "0")
        hwmon=$(ls -d "$card/device/hwmon/hwmon"* 2>/dev/null | head -1)
        if [ -n "$hwmon" ]; then
            temp=$(cat "$hwmon/temp1_input" 2>/dev/null || echo "0")
            power=$(cat "$hwmon/power1_average" 2>/dev/null || echo "0")
            fan=$(cat "$hwmon/fan1_input" 2>/dev/null || echo "0")
            fan_max=$(cat "$hwmon/fan1_max" 2>/dev/null || echo "1")
        else
            temp="0"
            power="0"
            fan="0"
            fan_max="1"
        fi
        echo "$idx|$util|$vram_used|$vram_total|$temp|$power|$fan|$fan_max"
    fi
done
"#;

    if let Ok(output) = client.execute_command(amd_sysfs_cmd).await {
        let output = output.trim();
        if !output.is_empty() {
            let mut gpus = Vec::new();
            for line in output.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                let parts: Vec<&str> = line.split('|').collect();
                if parts.len() >= 8 {
                    let index = parts[0].parse::<u32>().unwrap_or(0);
                    let utilization = parts[1].parse::<f64>().unwrap_or(0.0);
                    let memory_used = parts[2].parse::<u64>().unwrap_or(0) / (1024 * 1024);
                    let memory_total = parts[3].parse::<u64>().unwrap_or(1) / (1024 * 1024);
                    let memory_percent = if memory_total > 0 {
                        (memory_used as f64 / memory_total as f64) * 100.0
                    } else {
                        0.0
                    };

                    let temperature = parts[4].parse::<f64>().ok().map(|t| t / 1000.0);
                    let power_draw = parts[5].parse::<f64>().ok().map(|p| p / 1_000_000.0);
                    let fan_speed = match (parts[6].parse::<f64>(), parts[7].parse::<f64>()) {
                        (Ok(fan), Ok(max)) if max > 0.0 => Some((fan / max) * 100.0),
                        _ => None,
                    };

                    gpus.push(GpuStats {
                        index,
                        name: format!("AMD GPU {}", index),
                        vendor: GpuVendor::Amd,
                        utilization,
                        memory_used,
                        memory_total,
                        memory_percent,
                        temperature,
                        power_draw,
                        power_limit: None,
                        fan_speed,
                        encoder_util: None,
                        decoder_util: None,
                    });
                }
            }
            if !gpus.is_empty() {
                return Ok(GpuStatsResponse {
                    success: true,
                    gpus,
                    error: None,
                });
            }
        }
    }

    Ok(GpuStatsResponse {
        success: false,
        gpus: Vec::new(),
        error: Some("No GPU detected or drivers not installed".to_string()),
    })
}
