import SwiftUI
import OSLog

/// Modal sheet for editing a remote file's permissions, owner, and group.
/// Uses the Rust FFI (`rshellSftpChmod`, `rshellSftpChown`, `rshellSftpChgrp`)
/// to apply changes on the remote host.
struct FilePermissionsEditor: View {
    let connectionId: String
    let remotePath: String
    let entryName: String
    let currentPermissions: String?
    let currentOwner: String?
    let currentGroup: String?
    let onDone: () -> Void

    @State private var ownerRead = false
    @State private var ownerWrite = false
    @State private var ownerExec = false
    @State private var groupRead = false
    @State private var groupWrite = false
    @State private var groupExec = false
    @State private var otherRead = false
    @State private var otherWrite = false
    @State private var otherExec = false

    @State private var ownerText: String = ""
    @State private var groupText: String = ""
    @State private var applying = false
    @State private var error: String?
    @State private var resolvedOwner: String?
    @State private var resolvedGroup: String?

    @FocusState private var ownerFocused: Bool
    @FocusState private var groupFocused: Bool

    private let logger = Logger(subsystem: "com.r-shell", category: "permissions-editor")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions — \(entryName)")
                .font(.headline)

            // MARK: - Permission checkboxes
            GroupBox("Permissions") {
                HStack(spacing: 0) {
                    VStack(spacing: 8) {
                        Text("").frame(height: 20) // spacer row for header
                        headerLabel("r")
                        headerLabel("w")
                        headerLabel("x")
                    }
                    .frame(width: 24)
                    VStack(spacing: 8) {
                        headerLabel("Owner")
                        Toggle("", isOn: $ownerRead).labelsHidden()
                        Toggle("", isOn: $ownerWrite).labelsHidden()
                        Toggle("", isOn: $ownerExec).labelsHidden()
                    }
                    .frame(width: 48)
                    VStack(spacing: 8) {
                        headerLabel("Group")
                        Toggle("", isOn: $groupRead).labelsHidden()
                        Toggle("", isOn: $groupWrite).labelsHidden()
                        Toggle("", isOn: $groupExec).labelsHidden()
                    }
                    .frame(width: 48)
                    VStack(spacing: 8) {
                        headerLabel("Other")
                        Toggle("", isOn: $otherRead).labelsHidden()
                        Toggle("", isOn: $otherWrite).labelsHidden()
                        Toggle("", isOn: $otherExec).labelsHidden()
                    }
                    .frame(width: 48)
                    Spacer()
                }
                Text("Numeric: \(numericMode)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }

            // MARK: - Owner
            GroupBox("Owner") {
                HStack {
                    TextField("Owner (uid or name)", text: $ownerText)
                        .textFieldStyle(.roundedBorder)
                        .focused($ownerFocused)
                    if let name = resolvedOwner {
                        Text("→ \(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Resolve Name") {
                        resolveOwner()
                    }
                    .controlSize(.small)
                    .disabled(ownerText.isEmpty)
                    Button("Revert") {
                        ownerText = currentOwner ?? ""
                        resolvedOwner = nil
                    }
                    .controlSize(.small)
                }
            }

            // MARK: - Group
            GroupBox("Group") {
                HStack {
                    TextField("Group (gid or name)", text: $groupText)
                        .textFieldStyle(.roundedBorder)
                        .focused($groupFocused)
                    if let name = resolvedGroup {
                        Text("→ \(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Resolve Name") {
                        resolveGroup()
                    }
                    .controlSize(.small)
                    .disabled(groupText.isEmpty)
                    Button("Revert") {
                        groupText = currentGroup ?? ""
                        resolvedGroup = nil
                    }
                    .controlSize(.small)
                }
            }

            // MARK: - Error
            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Buttons
            HStack {
                if applying {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Revert all") {
                    populateFromCurrent()
                }
                .disabled(applying)
                Button("Cancel", role: .cancel) {
                    onDone()
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(applying)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            populateFromCurrent()
        }
    }

    // MARK: - Helpers

    private func headerLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 32, alignment: .center)
    }

    private var numericMode: String {
        let o = (ownerRead ? 4 : 0) + (ownerWrite ? 2 : 0) + (ownerExec ? 1 : 0)
        let g = (groupRead ? 4 : 0) + (groupWrite ? 2 : 0) + (groupExec ? 1 : 0)
        let w = (otherRead ? 4 : 0) + (otherWrite ? 2 : 0) + (otherExec ? 1 : 0)
        return "\(o)\(g)\(w)"
    }

    private func populateFromCurrent() {
        resolvedOwner = nil
        resolvedGroup = nil
        ownerText = currentOwner ?? ""
        groupText = currentGroup ?? ""
        error = nil

        guard let perms = currentPermissions, perms.count >= 9 else {
            (ownerRead, ownerWrite, ownerExec) = (false, false, false)
            (groupRead, groupWrite, groupExec) = (false, false, false)
            (otherRead, otherWrite, otherExec) = (false, false, false)
            return
        }
        let chars = Array(perms)
        ownerRead  = chars[0] == "r"
        ownerWrite = chars[1] == "w"
        ownerExec  = chars[2] == "x"
        groupRead  = chars[3] == "r"
        groupWrite = chars[4] == "w"
        groupExec  = chars[5] == "x"
        otherRead  = chars[6] == "r"
        otherWrite = chars[7] == "w"
        otherExec  = chars[8] == "x"
    }

    private func resolveOwner() {
        guard !ownerText.isEmpty else { return }
        Task.detached {
            do {
                let name = try rshellSftpResolveUid(connectionId: connectionId, uid: ownerText)
                await MainActor.run { resolvedOwner = name }
            } catch {
                await MainActor.run { resolvedOwner = "(not found)" }
            }
        }
    }

    private func resolveGroup() {
        guard !groupText.isEmpty else { return }
        Task.detached {
            do {
                let name = try rshellSftpResolveGid(connectionId: connectionId, gid: groupText)
                await MainActor.run { resolvedGroup = name }
            } catch {
                await MainActor.run { resolvedGroup = "(not found)" }
            }
        }
    }

    private func apply() {
        applying = true
        error = nil
        let mode = numericMode
        let owner = ownerText.trimmingCharacters(in: .whitespaces)
        let group = groupText.trimmingCharacters(in: .whitespaces)
        let connId = connectionId
        let path = remotePath

        Task.detached {
            var failures: [String] = []

            do {
                try rshellSftpChmod(connectionId: connId, path: path, mode: mode)
            } catch {
                failures.append("chmod: \(error.localizedDescription)")
            }

            if !owner.isEmpty && owner != currentOwner {
                do {
                    try rshellSftpChown(connectionId: connId, path: path, uid: owner)
                } catch {
                    failures.append("chown: \(error.localizedDescription)")
                }
            }

            if !group.isEmpty && group != currentGroup {
                do {
                    try rshellSftpChgrp(connectionId: connId, path: path, gid: group)
                } catch {
                    failures.append("chgrp: \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                applying = false
                if failures.isEmpty {
                    onDone()
                } else {
                    error = failures.joined(separator: "; ")
                }
            }
        }
    }
}
