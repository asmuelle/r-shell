import SwiftUI

struct MobileTerminalSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: MobileTerminalPreferences

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $preferences.themeId) {
                        ForEach(MobileTerminalTheme.all) { theme in
                            HStack {
                                Circle()
                                    .fill(Color(uiColor: theme.caret))
                                    .frame(width: 10, height: 10)
                                Text(theme.label)
                            }
                            .tag(theme.id)
                        }
                    }

                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(preferences.clampedFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: $preferences.fontSize,
                        in: 10...22,
                        step: 1
                    )

                    Picker("Cursor", selection: $preferences.cursorStyleId) {
                        ForEach(MobileTerminalCursorStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                }

                Section("Behavior") {
                    Picker("Scrollback", selection: $preferences.scrollbackLines) {
                        Text("1,000").tag(1_000)
                        Text("5,000").tag(5_000)
                        Text("10,000").tag(10_000)
                        Text("50,000").tag(50_000)
                        Text("100,000").tag(100_000)
                    }

                    Toggle("Mouse Reporting", isOn: $preferences.mouseReporting)
                    Toggle("Option as Meta", isOn: $preferences.optionAsMeta)
                }
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
