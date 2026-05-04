import SwiftUI

@main
struct MidnightSSHMobileApp: App {
    @StateObject private var bridgeManager = MobileBridgeManager.shared
    @StateObject private var keychainManager = MobileKeychainManager.shared
    @StateObject private var connectionStore = MobileConnectionStore()
    @StateObject private var sessionStore = MobileSessionStore()
    @StateObject private var terminalPreferences = MobileTerminalPreferences.shared
    @StateObject private var entitlementsStore = MobileEntitlementsStore.shared

    var body: some Scene {
        WindowGroup {
            MobilePrivacyGateView {
                MobileContentView()
            }
                .environmentObject(bridgeManager)
                .environmentObject(keychainManager)
                .environmentObject(connectionStore)
                .environmentObject(sessionStore)
                .environmentObject(terminalPreferences)
                .environmentObject(entitlementsStore)
                .task {
                    bridgeManager.initialize()
                    connectionStore.load()
                    entitlementsStore.start()
                }
        }
        .commands {
            SidebarCommands()
            CommandMenu("Server") {
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .mobileShowCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Reconnect") {
                    NotificationCenter.default.post(name: .mobileReconnectCurrent, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Tail Logs") {
                    NotificationCenter.default.post(name: .mobileTailLogs, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let mobileShowCommandPalette = Notification.Name("mobileShowCommandPalette")
    static let mobileReconnectCurrent = Notification.Name("mobileReconnectCurrent")
    static let mobileTailLogs = Notification.Name("mobileTailLogs")
}
