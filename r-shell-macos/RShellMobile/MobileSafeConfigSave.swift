import Foundation

struct MobileConfigBackup {
    let originalPath: String
    let backupPath: String
    let validator: MobileConfigValidator?
}

struct MobileConfigValidator {
    let label: String
    let command: (String) -> String
}

enum MobileSafeConfigSave {
    static func prepare(connectionId: String, remotePath: String, fileName: String) async throws -> MobileConfigBackup {
        let backupPath = "\(remotePath).midnight-ssh.\(timestamp()).bak"
        let validator = validator(for: remotePath, fileName: fileName)
        let backupResult = try await MobileRemoteTaskRunner.shared.run(
            connectionId: connectionId,
            title: "Create Backup",
            command: "cp -p \(shellQuote(remotePath)) \(shellQuote(backupPath))",
            risk: .mutating
        )
        guard backupResult.succeeded else {
            throw MobileSafeConfigSaveError.backupFailed(
                output: backupResult.output,
                backupPath: backupPath
            )
        }
        return MobileConfigBackup(originalPath: remotePath, backupPath: backupPath, validator: validator)
    }

    static func validate(
        connectionId: String,
        backup: MobileConfigBackup
    ) async throws -> MobileRemoteTaskResult? {
        guard let validator = backup.validator else { return nil }
        let result = try await MobileRemoteTaskRunner.shared.run(
            connectionId: connectionId,
            title: validator.label,
            command: validator.command(backup.originalPath),
            risk: .readOnly
        )
        guard result.succeeded else {
            _ = try? await MobileRemoteTaskRunner.shared.run(
                connectionId: connectionId,
                title: "Rollback Config",
                command: "cp -p \(shellQuote(backup.backupPath)) \(shellQuote(backup.originalPath))",
                risk: .mutating
            )
            throw MobileSafeConfigSaveError.validationFailed(
                validator: validator.label,
                output: result.output,
                backupPath: backup.backupPath
            )
        }
        return result
    }

    static func validator(for remotePath: String, fileName: String) -> MobileConfigValidator? {
        let lowerPath = remotePath.lowercased()
        let lowerName = fileName.lowercased()

        if lowerName.hasSuffix(".service") {
            return MobileConfigValidator(label: "Validate systemd unit") { path in
                "systemd-analyze verify \(shellQuote(path)) 2>&1"
            }
        }
        if lowerPath.contains("/etc/nginx/") || lowerName.contains("nginx") {
            return MobileConfigValidator(label: "Validate nginx") { _ in
                "nginx -t 2>&1"
            }
        }
        if lowerPath.hasSuffix("/sshd_config") || lowerName == "sshd_config" {
            return MobileConfigValidator(label: "Validate sshd") { _ in
                "sshd -t 2>&1"
            }
        }
        if lowerPath.contains("/postfix/") {
            return MobileConfigValidator(label: "Validate postfix") { _ in
                "postfix check 2>&1"
            }
        }
        if lowerName.hasSuffix(".sh") {
            return MobileConfigValidator(label: "Validate shell script") { path in
                "bash -n \(shellQuote(path)) 2>&1"
            }
        }
        if lowerName.hasSuffix(".yaml") || lowerName.hasSuffix(".yml") {
            return MobileConfigValidator(label: "Validate YAML syntax") { path in
                """
                if command -v python3 >/dev/null 2>&1; then
                  python3 - \(shellQuote(path)) <<'PY'
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

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

enum MobileSafeConfigSaveError: LocalizedError {
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
