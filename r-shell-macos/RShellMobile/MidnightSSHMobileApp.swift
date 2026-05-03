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
    }
}
