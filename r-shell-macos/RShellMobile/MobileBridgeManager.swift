import Foundation

@MainActor
final class MobileBridgeManager: ObservableObject {
    static let shared = MobileBridgeManager()

    @Published private(set) var initialized = false
    @Published private(set) var initializationError: String?

    private var eventCallback: MobileEventCallback?

    private init() {}

    func initialize() {
        guard !initialized else { return }

        if rshellInit() {
            let callback = MobileEventCallback()
            rshellSetEventCallback(callback: callback)
            eventCallback = callback
            initialized = true
            initializationError = nil
        } else {
            initialized = false
            initializationError = "The Rust bridge could not be initialized."
        }
    }
}

final class MobileEventCallback: FfiEventCallback {
    func onEvent(event: FfiEvent) {
        switch event.ty {
        case "pty_output":
            Task { @MainActor in
                MobileTerminalSessionManager.shared.dispatch(
                    connectionId: event.connectionId,
                    type: event.ty,
                    payload: event.payload
                )
            }
        default:
            break
        }
    }
}
