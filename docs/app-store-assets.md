# midnight-ssh Marketplace Assets

## Positioning

Mac-native SSH operations cockpit for people who maintain Linux servers.

## Short Description

Monitor, troubleshoot, edit, and transfer files across SSH servers from one native Mac workspace.

## Subtitle Candidates

- Mac-native SSH operations cockpit
- Terminal, SFTP, and server diagnostics
- Linux server workbench for macOS

## App Store Description Draft

midnight-ssh is a native macOS SSH client for server operators who need more than a terminal window. It combines saved connections, SSH terminals, SFTP file browsing, remote config editing, service monitoring, firewall insight, and multi-server dashboards in one focused workspace.

Use it to connect quickly, inspect system health, review systemd services, investigate UFW activity, edit common config files, and compare multiple servers side by side. Credentials are stored in macOS Keychain, SSH host keys are trusted locally, and diagnostics exports are redacted for support.

## Screenshot Plan

| Slot | Scene | Message |
| --- | --- | --- |
| 1 | Multi-server dashboard | Compare connected servers side by side. |
| 2 | Terminal and SFTP split | Work in the shell and file system together. |
| 3 | Monitor pane | CPU, memory, disk, services, and firewall status at a glance. |
| 4 | Systemd drill-down | Investigate service status, logs, environment, and actions. |
| 5 | UFW/IP map | See blocked and connected IP activity geographically. |
| 6 | Remote editor | Edit YAML, shell, SQL, text, dotfiles, and systemd unit files. |

## Review Demo Script

1. Open the app in demo mode.
2. Select the bundled sample connection named `Demo Server`.
3. Open the dashboard and show two simulated connected hosts.
4. Open the monitor pane and click CPU, memory, disk, UFW, and a monitored systemd service.
5. Open SFTP and double-click a `.service` file to show syntax highlighting.
6. Export a diagnostics bundle and confirm hostnames/usernames are redacted.

## Keywords

ssh, sftp, terminal, linux, systemd, firewall, ufw, devops, server, config

## Support Commitments

- Support URL must explain credential storage, host-key trust, and diagnostics redaction.
- Privacy policy must state that no server credentials are collected.
- Review notes should explain that live SSH access requires a server, and demo mode is provided for review.
