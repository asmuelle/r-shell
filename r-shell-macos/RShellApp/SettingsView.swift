import SwiftUI
import RShellMacOS

/// Settings panel with Terminal, Appearance, and Credentials tabs.
struct SettingsView: View {
    @AppStorage("defaultColumns") private var defaultColumns = 80
    @AppStorage("defaultRows") private var defaultRows = 24
    @AppStorage("fontSize") private var fontSize = 12.0
    @AppStorage("terminalTheme") private var terminalTheme = "system"

    @StateObject private var connectionStore = ConnectionStoreManager.shared
    @State private var selectedConnections = Set<String>()

    var body: some View {
        TabView {
            terminalSettings
                .tabItem { Label("Terminal", systemImage: "terminal") }

            appearanceSettings
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            credentialsSettings
                .tabItem { Label("Credentials", systemImage: "key") }
        }
        .frame(width: 520, height: 420)
    }

    // MARK: - Terminal tab

    private var terminalSettings: some View {
        Form {
            Section("Defaults") {
                Picker("Default columns", selection: $defaultColumns) {
                    ForEach([80, 100, 120, 160], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }

                Picker("Default rows", selection: $defaultRows) {
                    ForEach([24, 40, 48, 60], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
            }

            Section {
                Text("These values are used when opening new terminal tabs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance tab

    private var appearanceSettings: some View {
        Form {
            Section("Typography") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $fontSize, in: 8...24, step: 1)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Section {
                Picker("Theme", selection: $terminalTheme) {
                    Text("Follow system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Terminal colours")
            } footer: {
                Text("Background / foreground / caret. Named ANSI palettes (Solarized, Dracula, Nord) come in a later release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Credentials tab

    private var credentialsSettings: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                    Text("macOS Keychain")
                        .font(.headline)
                    Spacer()
                    Text("Available")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Keychain provides encrypted storage for your credentials separately from the app database. Keychain entries persist even if the app is uninstalled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Saved credentials") {
                if connectionStore.connections.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "key.slash")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("No saved credentials")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    List(selection: $selectedConnections) {
                        ForEach(connectionStore.connections) { conn in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conn.name)
                                    Text(conn.keychainAccount)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                            .tag(conn.id)
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                connectionStore.delete(connectionStore.connections[idx])
                            }
                        }
                    }
                    .frame(minHeight: 140)
                }
            }

            if !connectionStore.connections.isEmpty {
                Section {
                    HStack {
                        Button("Remove Selected") {
                            for id in selectedConnections {
                                if let conn = connectionStore.connection(withId: id) {
                                    connectionStore.delete(conn)
                                }
                            }
                            selectedConnections.removeAll()
                        }
                        .disabled(selectedConnections.isEmpty)

                        Spacer()

                        Button("Import from Tauri…") {
                            importFromTauri()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importFromTauri() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Select the Tauri export JSON file"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                _ = connectionStore.importFromTauriJSON(url: url)
            }
        }
    }
}
