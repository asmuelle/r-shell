import SwiftUI

struct MobileTerminalCommandPaletteView: View {
    let perform: (MobileTerminalCommand) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(MobileTerminalCommand.allCases) { command in
                Button {
                    dismiss()
                    perform(command)
                } label: {
                    Label(command.label, systemImage: command.systemImage)
                }
            }
            .navigationTitle("Terminal Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
