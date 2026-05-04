import Foundation

struct MacConfigBackup {
    let originalPath: String
    let backupPath: String
    let validator: MacConfigValidator?
}

struct MacConfigValidator {
    let label: String
    let command: (String) -> String
}

enum MacSafeConfigSave {
    static func prepareIfNeeded(connectionId: String, remotePath: String) async throws -> MacConfigBackup? {
        guard shouldBackup(remotePath) else { return nil }
        let backupPath = "\(remotePath).midnight-ssh.\(timestamp()).bak"
        let result = try await RemoteCommandRunner.runShell(
            connectionId: connectionId,
            script: "cp -p \(RemoteCommandRunner.shellQuote(remotePath)) \(RemoteCommandRunner.shellQuote(backupPath))"
        )
        guard result.succeeded else {
            throw MacSafeConfigSaveError.backupFailed(output: result.output, backupPath: backupPath)
        }
        return MacConfigBackup(
            originalPath: remotePath,
            backupPath: backupPath,
            validator: validator(for: remotePath)
        )
    }

    static func validate(connectionId: String, backup: MacConfigBackup) async throws -> RemoteCommandResult? {
        guard let validator = backup.validator else { return nil }
        let result = try await RemoteCommandRunner.runShell(
            connectionId: connectionId,
            script: validator.command(backup.originalPath)
        )
        guard result.succeeded else {
            _ = try? await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: "cp -p \(RemoteCommandRunner.shellQuote(backup.backupPath)) \(RemoteCommandRunner.shellQuote(backup.originalPath))"
            )
            throw MacSafeConfigSaveError.validationFailed(
                validator: validator.label,
                output: result.output,
                backupPath: backup.backupPath
            )
        }
        return result
    }

    static func shouldBackup(_ remotePath: String) -> Bool {
        let fileName = (remotePath as NSString).lastPathComponent
        let ext = (remotePath as NSString).pathExtension.lowercased()
        if fileName.hasPrefix("."), fileName != ".", fileName != ".." { return true }
        if remotePath.hasPrefix("/etc/") || remotePath.hasPrefix("/usr/local/etc/") { return true }
        return ["service", "sh", "yaml", "yml", "sql"].contains(ext)
    }

    private static func validator(for remotePath: String) -> MacConfigValidator? {
        let lowerPath = remotePath.lowercased()
        let lowerName = (remotePath as NSString).lastPathComponent.lowercased()

        if lowerName.hasSuffix(".service") {
            return MacConfigValidator(label: "systemd unit validation") { path in
                "systemd-analyze verify \(RemoteCommandRunner.shellQuote(path)) 2>&1"
            }
        }
        if lowerPath.contains("/etc/nginx/") || lowerName.contains("nginx") {
            return MacConfigValidator(label: "nginx validation") { _ in
                "nginx -t 2>&1"
            }
        }
        if lowerPath.hasSuffix("/sshd_config") || lowerName == "sshd_config" {
            return MacConfigValidator(label: "sshd validation") { _ in
                "sshd -t 2>&1"
            }
        }
        if lowerPath.contains("/postfix/") {
            return MacConfigValidator(label: "postfix validation") { _ in
                "postfix check 2>&1"
            }
        }
        if lowerName.hasSuffix(".sh") {
            return MacConfigValidator(label: "shell syntax validation") { path in
                "bash -n \(RemoteCommandRunner.shellQuote(path)) 2>&1"
            }
        }
        if lowerName.hasSuffix(".yaml") || lowerName.hasSuffix(".yml") {
            return MacConfigValidator(label: "YAML syntax validation") { path in
                """
                if command -v python3 >/dev/null 2>&1; then
                  python3 - \(RemoteCommandRunner.shellQuote(path)) <<'PY'
                import sys
                try:
                    import yaml
                except Exception:
                    sys.exit(0)
                with open(sys.argv[1], 'r', encoding='utf-8') as handle:
                    yaml.safe_load(handle)
                PY
                fi
                """
            }
        }
        return nil
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

enum MacSafeConfigSaveError: LocalizedError {
    case backupFailed(output: String, backupPath: String)
    case validationFailed(validator: String, output: String, backupPath: String)

    var errorDescription: String? {
        switch self {
        case .backupFailed(let output, let backupPath):
            return "Could not create a backup at \(backupPath).\n\n\(output)"
        case .validationFailed(let validator, let output, let backupPath):
            return "\(validator) failed. The original file was restored from \(backupPath).\n\n\(output)"
        }
    }
}
