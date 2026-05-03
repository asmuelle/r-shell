import SwiftUI

struct MobileTerminalAccessoryBar: View {
    @EnvironmentObject private var terminalPreferences: MobileTerminalPreferences

    let connectionId: String

    @State private var controlLatched = false
    @State private var altLatched = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                latchButton("Ctrl", isActive: controlLatched) {
                    controlLatched.toggle()
                }
                latchButton("Alt", isActive: altLatched) {
                    altLatched.toggle()
                }

                Divider()
                    .frame(height: 24)

                keyButton("Esc") { send(.escape) }
                keyButton("Tab") { send(.tab) }

                Divider()
                    .frame(height: 24)

                iconButton("chevron.left", "Left") { send(.left) }
                iconButton("chevron.down", "Down") { send(.down) }
                iconButton("chevron.up", "Up") { send(.up) }
                iconButton("chevron.right", "Right") { send(.right) }

                Divider()
                    .frame(height: 24)

                keyButton("/") { send(.text("/")) }
                keyButton("-") { send(.text("-")) }
                keyButton("|") { send(.text("|")) }
                keyButton("~") { send(.text("~")) }

                Divider()
                    .frame(height: 24)

                keyButton("C") { send(.text("c")) }
                keyButton("D") { send(.text("d")) }
                keyButton("L") { send(.text("l")) }
                keyButton("Enter") { send(.enter) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .background(themeBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(themeForeground.opacity(0.14))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var themeBackground: Color {
        Color(uiColor: terminalPreferences.theme.background)
    }

    private var themeForeground: Color {
        Color(uiColor: terminalPreferences.theme.foreground)
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(themeForeground)
                .frame(minWidth: title.count > 1 ? 44 : 32, minHeight: 30)
                .background(themeForeground.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemName: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .foregroundStyle(themeForeground)
                .frame(width: 32, height: 30)
                .background(themeForeground.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func latchButton(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(isActive ? .black : themeForeground)
                .frame(minWidth: 44, minHeight: 30)
                .background(
                    isActive ? Color.green : themeForeground.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) modifier")
        .accessibilityValue(isActive ? "On" : "Off")
    }

    private func send(_ key: MobileTerminalAccessoryKey) {
        let data = key.data(control: controlLatched, alt: altLatched)
        MobileTerminalBridge.shared.sendInput(connectionId: connectionId, data: data)

        if controlLatched {
            controlLatched = false
        }
        if altLatched {
            altLatched = false
        }
    }
}

private enum MobileTerminalAccessoryKey {
    case escape
    case tab
    case enter
    case left
    case right
    case up
    case down
    case text(String)

    func data(control: Bool, alt: Bool) -> Data {
        var bytes: [UInt8] = []
        if alt {
            bytes.append(0x1B)
        }

        switch self {
        case .escape:
            bytes.append(0x1B)
        case .tab:
            bytes.append(control ? 0x09 : 0x09)
        case .enter:
            bytes.append(control ? 0x0A : 0x0D)
        case .left:
            bytes.append(contentsOf: control ? [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x44] : [0x1B, 0x5B, 0x44])
        case .right:
            bytes.append(contentsOf: control ? [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43] : [0x1B, 0x5B, 0x43])
        case .up:
            bytes.append(contentsOf: control ? [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41] : [0x1B, 0x5B, 0x41])
        case .down:
            bytes.append(contentsOf: control ? [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x42] : [0x1B, 0x5B, 0x42])
        case .text(let value):
            bytes.append(contentsOf: textBytes(value, control: control))
        }

        return Data(bytes)
    }

    private func textBytes(_ value: String, control: Bool) -> [UInt8] {
        guard control else {
            return Array(value.utf8)
        }

        switch value.lowercased() {
        case "a":
            return [0x01]
        case "b":
            return [0x02]
        case "c":
            return [0x03]
        case "d":
            return [0x04]
        case "e":
            return [0x05]
        case "f":
            return [0x06]
        case "g":
            return [0x07]
        case "h":
            return [0x08]
        case "i":
            return [0x09]
        case "j":
            return [0x0A]
        case "k":
            return [0x0B]
        case "l":
            return [0x0C]
        case "m":
            return [0x0D]
        case "n":
            return [0x0E]
        case "o":
            return [0x0F]
        case "p":
            return [0x10]
        case "q":
            return [0x11]
        case "r":
            return [0x12]
        case "s":
            return [0x13]
        case "t":
            return [0x14]
        case "u":
            return [0x15]
        case "v":
            return [0x16]
        case "w":
            return [0x17]
        case "x":
            return [0x18]
        case "y":
            return [0x19]
        case "z":
            return [0x1A]
        case "[":
            return [0x1B]
        case "\\":
            return [0x1C]
        case "]":
            return [0x1D]
        case "^":
            return [0x1E]
        case "/":
            return [0x1F]
        default:
            return Array(value.utf8)
        }
    }
}
