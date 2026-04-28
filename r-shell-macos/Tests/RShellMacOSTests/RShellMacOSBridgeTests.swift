// RShellMacOSBridgeTests — XCTest harness that proves the FFI bridge works.
//
// Run from Xcode or via:
//   swift test --package r-shell-macos
//
// Prerequisites:
//   1. cargo build -p r-shell-macos --release
//   2. uniffi-bindgen generate ... (see Package.swift / build.rs)
//   3. Xcode project configured with the generated module map and header

import XCTest
@testable import RShellMacOS

final class RShellMacOSBridgeTests: XCTestCase {

    /// 1. Initialisation succeeds.
    func testInit() throws {
        XCTAssertTrue(rshellInit(), "bridge initialisation must return true")
    }

    /// 2. Connecting with no auth method returns a descriptive error,
    ///    proving the error path works across the FFI boundary.
    func testConnectWithoutAuthReturnsError() throws {
        _ = rshellInit()

        let config = FfiConnectConfig(
            host: "192.0.2.1",
            port: 22,
            username: "test",
            password: nil,
            keyPath: nil,
            passphrase: nil
        )

        let result = rshell_connect(config: config)
        XCTAssertFalse(result.success, "connect with no auth must fail")
        XCTAssertNotNil(result.error, "error must be populated")
        XCTAssertTrue(
            result.error!.contains("password") || result.error!.contains("key"),
            "error must mention missing auth: \(result.error!)"
        )
    }

    /// 3. Disconnecting an unknown connection is a no-op, not an error.
    func testDisconnectUnknownIsOk() throws {
        _ = rshellInit()
        let result = rshell_disconnect(connectionId: "does-not-exist")
        XCTAssertTrue(result.success, "disconnecting unknown id should succeed")
    }

    /// 4. Starting a PTY on a non-existent connection returns an error.
    func testPtyStartOnNonexistentConnection() throws {
        _ = rshellInit()
        let result = rshell_pty_start(
            connectionId: "no-such-connection",
            cols: 80,
            rows: 24
        )
        XCTAssertFalse(result.success, "PTY on unknown connection must fail")
        XCTAssertNotNil(result.error, "error must be populated")
    }

    /// 5. Event callback registration and delivery.
    func testEventCallbackReceivesEvents() throws {
        _ = rshellInit()

        let expectation = self.expectation(description: "event callback fired")

        class TestCallback: FfiEventCallback {
            let exp: XCTestExpectation
            init(_ exp: XCTestExpectation) { self.exp = exp }
            func onEvent(event: FfiEvent) {
                print("received event: type=\(event.ty) id=\(event.connectionId)")
                exp.fulfill()
            }
        }

        let callback = TestCallback(expectation)
        rshell_set_event_callback(callback: callback)

        wait(for: [expectation], timeout: 5.0)
        // Note: this test passes if the callback fires within 5 seconds.
        // Events come from the Rust core layer automatically after init.
    }
}
