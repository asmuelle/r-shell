//! Local filesystem commands and recursive listing helpers used by the
//! directory-sync workflow.

use crate::connection_manager::ConnectionManager;
use crate::sftp_client::{format_unix_timestamp, FileEntry, FileEntryType};
use serde::Serialize;
use std::sync::Arc;
use tauri::State;

// ---------------------------------------------------------------------------
// Single-directory listing.
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn list_local_files(path: String) -> Result<Vec<FileEntry>, String> {
    use std::fs;

    let dir_path = std::path::Path::new(&path);
    if !dir_path.exists() {
        return Err(format!("Path does not exist: {}", path));
    }
    if !dir_path.is_dir() {
        return Err(format!("Path is not a directory: {}", path));
    }

    let read_dir = fs::read_dir(dir_path)
        .map_err(|e| format!("Failed to read directory '{}': {}", path, e))?;

    let mut entries: Vec<FileEntry> = Vec::new();
    for item in read_dir {
        let item = match item {
            Ok(i) => i,
            Err(_) => continue,
        };

        let name = item.file_name().to_string_lossy().to_string();
        let metadata = match item.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };

        let file_type = if metadata.is_dir() {
            FileEntryType::Directory
        } else if metadata.file_type().is_symlink() {
            FileEntryType::Symlink
        } else {
            FileEntryType::File
        };

        let size = metadata.len();

        let modified = metadata.modified().ok().map(|t| {
            let duration = t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
            let secs = duration.as_secs() as i64;
            format_unix_timestamp(secs)
        });

        #[cfg(unix)]
        let permissions = {
            use std::os::unix::fs::PermissionsExt;
            let mode = metadata.permissions().mode();
            Some(format_unix_permissions(mode))
        };
        #[cfg(not(unix))]
        let permissions: Option<String> = None;

        entries.push(FileEntry {
            name,
            size,
            modified,
            permissions,
            file_type,
        });
    }

    entries.sort_by(|a, b| {
        let a_is_dir = matches!(a.file_type, FileEntryType::Directory);
        let b_is_dir = matches!(b.file_type, FileEntryType::Directory);
        match (a_is_dir, b_is_dir) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
        }
    });

    Ok(entries)
}

/// Format Unix file mode bits into a human-readable rwx string.
#[cfg(unix)]
fn format_unix_permissions(mode: u32) -> String {
    let mut s = String::with_capacity(10);
    s.push(match mode & 0o170000 {
        0o040000 => 'd',
        0o120000 => 'l',
        _ => '-',
    });
    s.push(if mode & 0o400 != 0 { 'r' } else { '-' });
    s.push(if mode & 0o200 != 0 { 'w' } else { '-' });
    s.push(if mode & 0o100 != 0 { 'x' } else { '-' });
    s.push(if mode & 0o040 != 0 { 'r' } else { '-' });
    s.push(if mode & 0o020 != 0 { 'w' } else { '-' });
    s.push(if mode & 0o010 != 0 { 'x' } else { '-' });
    s.push(if mode & 0o004 != 0 { 'r' } else { '-' });
    s.push(if mode & 0o002 != 0 { 'w' } else { '-' });
    s.push(if mode & 0o001 != 0 { 'x' } else { '-' });
    s
}

#[tauri::command]
pub async fn get_home_directory() -> Result<String, String> {
    dirs::home_dir()
        .map(|p| p.to_string_lossy().to_string())
        .ok_or_else(|| "Could not determine home directory".to_string())
}

#[tauri::command]
pub async fn delete_local_item(path: String, is_directory: bool) -> Result<(), String> {
    use std::fs;
    let p = std::path::Path::new(&path);
    if !p.exists() {
        return Err(format!("Path does not exist: {}", path));
    }
    if is_directory {
        fs::remove_dir_all(p).map_err(|e| format!("Failed to delete directory '{}': {}", path, e))
    } else {
        fs::remove_file(p).map_err(|e| format!("Failed to delete file '{}': {}", path, e))
    }
}

#[tauri::command]
pub async fn rename_local_item(old_path: String, new_path: String) -> Result<(), String> {
    use std::fs;
    let p = std::path::Path::new(&old_path);
    if !p.exists() {
        return Err(format!("Path does not exist: {}", old_path));
    }
    fs::rename(&old_path, &new_path)
        .map_err(|e| format!("Failed to rename '{}' to '{}': {}", old_path, new_path, e))
}

#[tauri::command]
pub async fn create_local_directory(path: String) -> Result<(), String> {
    use std::fs;
    fs::create_dir_all(&path).map_err(|e| format!("Failed to create directory '{}': {}", path, e))
}

#[tauri::command]
pub async fn open_in_os(path: String) -> Result<(), String> {
    open::that(&path).map_err(|e| format!("Failed to open '{}': {}", path, e))
}

// ---------------------------------------------------------------------------
// Directory synchronisation — recursive listings on both sides.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct SyncFileEntry {
    pub relative_path: String,
    pub name: String,
    pub size: u64,
    pub modified: Option<String>,
    pub file_type: FileEntryType,
}

#[tauri::command]
pub async fn list_local_files_recursive(
    path: String,
    exclude_patterns: Vec<String>,
) -> Result<Vec<SyncFileEntry>, String> {
    use std::fs;

    fn walk_dir(
        base: &std::path::Path,
        current: &std::path::Path,
        exclude: &[String],
        results: &mut Vec<SyncFileEntry>,
    ) -> Result<(), String> {
        let read_dir = fs::read_dir(current)
            .map_err(|e| format!("Failed to read '{}': {}", current.display(), e))?;

        for item in read_dir {
            let item = match item {
                Ok(i) => i,
                Err(_) => continue,
            };
            let name = item.file_name().to_string_lossy().to_string();

            if matches_exclude(&name, exclude) {
                continue;
            }

            let metadata = match item.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };

            let rel_path = item
                .path()
                .strip_prefix(base)
                .unwrap_or(item.path().as_path())
                .to_string_lossy()
                .to_string();

            let file_type = if metadata.is_dir() {
                FileEntryType::Directory
            } else if metadata.file_type().is_symlink() {
                FileEntryType::Symlink
            } else {
                FileEntryType::File
            };

            let modified = metadata.modified().ok().map(|t| {
                let duration = t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
                let secs = duration.as_secs() as i64;
                format_unix_timestamp(secs)
            });

            results.push(SyncFileEntry {
                relative_path: rel_path.clone(),
                name: name.clone(),
                size: metadata.len(),
                modified,
                file_type: file_type.clone(),
            });

            if metadata.is_dir() {
                walk_dir(base, &item.path(), exclude, results)?;
            }
        }
        Ok(())
    }

    let base_path = std::path::Path::new(&path);
    if !base_path.exists() || !base_path.is_dir() {
        return Err(format!(
            "Path does not exist or is not a directory: {}",
            path
        ));
    }

    let mut results = Vec::new();
    walk_dir(base_path, base_path, &exclude_patterns, &mut results)?;

    results.sort_by(|a, b| {
        let a_dir = matches!(a.file_type, FileEntryType::Directory);
        let b_dir = matches!(b.file_type, FileEntryType::Directory);
        match (a_dir, b_dir) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.relative_path.cmp(&b.relative_path),
        }
    });

    Ok(results)
}

#[tauri::command]
pub async fn list_remote_files_recursive(
    connection_id: String,
    path: String,
    exclude_patterns: Vec<String>,
    state: State<'_, Arc<ConnectionManager>>,
) -> Result<Vec<SyncFileEntry>, String> {
    let conn_type = state
        .get_connection_type(&connection_id)
        .await
        .ok_or_else(|| format!("No file connection found for '{}'", connection_id))?;

    let mut results = Vec::new();

    match conn_type.as_str() {
        "SFTP" => {
            let client_arc = state
                .get_sftp_client(&connection_id)
                .await
                .ok_or("SFTP connection not found")?;
            let client = client_arc.read().await;

            fn walk_sftp<'a>(
                client: &'a crate::sftp_client::StandaloneSftpClient,
                base: &'a str,
                current: &'a str,
                exclude: &'a [String],
                results: &'a mut Vec<SyncFileEntry>,
            ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), String>> + Send + 'a>>
            {
                Box::pin(async move {
                    let entries = client.list_dir(current).await.map_err(|e| e.to_string())?;
                    for entry in entries {
                        if matches_exclude(&entry.name, exclude) {
                            continue;
                        }
                        let full_path = if current == "/" {
                            format!("/{}", entry.name)
                        } else {
                            format!("{}/{}", current, entry.name)
                        };
                        let rel = full_path
                            .strip_prefix(base)
                            .unwrap_or(&full_path)
                            .trim_start_matches('/')
                            .to_string();

                        let is_dir = matches!(entry.file_type, FileEntryType::Directory);

                        results.push(SyncFileEntry {
                            relative_path: rel.clone(),
                            name: entry.name.clone(),
                            size: entry.size,
                            modified: entry.modified.clone(),
                            file_type: entry.file_type.clone(),
                        });

                        if is_dir {
                            walk_sftp(client, base, &full_path, exclude, results).await?;
                        }
                    }
                    Ok(())
                })
            }

            walk_sftp(&*client, &path, &path, &exclude_patterns, &mut results).await?;
        }
        "FTP" => {
            let client_arc = state
                .get_ftp_client(&connection_id)
                .await
                .ok_or("FTP connection not found")?;
            let mut client = client_arc.write().await;

            // Iterative walk with a stack — FTP needs &mut on every call.
            let mut dirs_to_visit: Vec<String> = vec![path.clone()];
            while let Some(dir) = dirs_to_visit.pop() {
                let entries = client.list_dir(&dir).await.map_err(|e| e.to_string())?;
                for entry in entries {
                    if matches_exclude(&entry.name, &exclude_patterns) {
                        continue;
                    }
                    let full_path = if dir == "/" {
                        format!("/{}", entry.name)
                    } else {
                        format!("{}/{}", dir, entry.name)
                    };
                    let rel = full_path
                        .strip_prefix(&path)
                        .unwrap_or(&full_path)
                        .trim_start_matches('/')
                        .to_string();

                    let is_dir = matches!(entry.file_type, FileEntryType::Directory);

                    results.push(SyncFileEntry {
                        relative_path: rel.clone(),
                        name: entry.name.clone(),
                        size: entry.size,
                        modified: entry.modified.clone(),
                        file_type: entry.file_type.clone(),
                    });

                    if is_dir {
                        dirs_to_visit.push(full_path);
                    }
                }
            }
        }
        _ => return Err(format!("Unsupported protocol: {}", conn_type)),
    }

    results.sort_by(|a, b| {
        let a_dir = matches!(a.file_type, FileEntryType::Directory);
        let b_dir = matches!(b.file_type, FileEntryType::Directory);
        match (a_dir, b_dir) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.relative_path.cmp(&b.relative_path),
        }
    });

    Ok(results)
}

/// Simple glob-like pattern matching for exclude filter. Supports `*.ext`
/// extension globs and exact-name matches.
fn matches_exclude(name: &str, patterns: &[String]) -> bool {
    for pat in patterns {
        if let Some(ext) = pat.strip_prefix('*') {
            if name.ends_with(ext) {
                return true;
            }
        } else if name == pat {
            return true;
        }
    }
    false
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn create_test_dir() -> TempDir {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("file1.txt"), "hello").unwrap();
        fs::write(dir.path().join("file2.rs"), "fn main() {}").unwrap();
        fs::create_dir(dir.path().join("subdir")).unwrap();
        fs::write(dir.path().join("subdir").join("nested.txt"), "nested").unwrap();
        dir
    }

    #[tokio::test]
    async fn test_list_local_files() {
        let dir = create_test_dir();
        let path = dir.path().to_string_lossy().to_string();
        let entries = list_local_files(path).await.unwrap();
        assert_eq!(entries[0].name, "subdir");
        assert!(matches!(entries[0].file_type, FileEntryType::Directory));
        let file_names: Vec<&str> = entries[1..].iter().map(|e| e.name.as_str()).collect();
        assert!(file_names.contains(&"file1.txt"));
        assert!(file_names.contains(&"file2.rs"));
    }

    #[tokio::test]
    async fn test_list_local_files_nonexistent() {
        let result = list_local_files("/nonexistent/path/xyz".to_string()).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("does not exist"));
    }

    #[tokio::test]
    async fn test_get_home_directory() {
        let home = get_home_directory().await.unwrap();
        assert!(!home.is_empty());
        assert!(std::path::Path::new(&home).exists());
    }

    #[tokio::test]
    async fn test_delete_local_file() {
        let dir = create_test_dir();
        let file_path = dir.path().join("file1.txt").to_string_lossy().to_string();
        assert!(std::path::Path::new(&file_path).exists());
        delete_local_item(file_path.clone(), false).await.unwrap();
        assert!(!std::path::Path::new(&file_path).exists());
    }

    #[tokio::test]
    async fn test_delete_local_directory() {
        let dir = create_test_dir();
        let sub_path = dir.path().join("subdir").to_string_lossy().to_string();
        assert!(std::path::Path::new(&sub_path).exists());
        delete_local_item(sub_path.clone(), true).await.unwrap();
        assert!(!std::path::Path::new(&sub_path).exists());
    }

    #[tokio::test]
    async fn test_rename_local_item() {
        let dir = create_test_dir();
        let old_path = dir.path().join("file1.txt").to_string_lossy().to_string();
        let new_path = dir.path().join("renamed.txt").to_string_lossy().to_string();
        rename_local_item(old_path.clone(), new_path.clone())
            .await
            .unwrap();
        assert!(!std::path::Path::new(&old_path).exists());
        assert!(std::path::Path::new(&new_path).exists());
    }

    #[tokio::test]
    async fn test_create_local_directory() {
        let dir = create_test_dir();
        let new_dir = dir.path().join("new_subdir").to_string_lossy().to_string();
        create_local_directory(new_dir.clone()).await.unwrap();
        assert!(std::path::Path::new(&new_dir).is_dir());
    }

    #[test]
    #[cfg(unix)]
    fn test_format_unix_permissions() {
        assert_eq!(format_unix_permissions(0o100644), "-rw-r--r--");
        assert_eq!(format_unix_permissions(0o040755), "drwxr-xr-x");
        assert_eq!(format_unix_permissions(0o100755), "-rwxr-xr-x");
        assert_eq!(format_unix_permissions(0o120777), "lrwxrwxrwx");
    }
}
