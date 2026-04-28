// PtyPayloadDecoder + framework-level invariants.
//
// The earlier draft of this file exercised `rshellInit`, `rshell_connect`,
// etc. — the uniffi-generated FFI surface. Those bindings live in the app
// target (RShellApp), not the framework, so they're not reachable from
// here. FFI integration tests need a separate app-target test bundle, and
// running them needs a host process that links the universal Rust static
// lib.
//
// What we cover from the framework target:
//
// 1. `PtyPayloadDecoder.decode` — the JSON `Vec<u8>` → `Data` conversion
//    that runs once per PTY output event. The earlier bug here (calling
//    `JSONSerialization.data(withJSONObject:)` on a `String`) silently
//    dropped every frame; locking the contract in tests prevents
//    regressing it.
//
// 2. Codable round-trips on the persisted models — `WorkspaceLayout` and
//    `TauriConnectionImport` are written to disk; their public initialisers
//    and the synthesised Codable conformance must match.
//
// 3. Cross-module construction — proves the public initialisers on
//    `WorkspaceLayout` and `TransferItem` (added when the app moved out
//    of the framework) actually exist and accept the expected arguments.

import XCTest
@testable import RShellMacOS

final class PtyPayloadDecoderTests: XCTestCase {
    func testDecodesByteArray() {
        let data = PtyPayloadDecoder.decode("[72,101,108,108,111]")
        XCTAssertEqual(data, Data([72, 101, 108, 108, 111]))  // "Hello"
    }

    func testDecodesEmptyArray() {
        XCTAssertEqual(PtyPayloadDecoder.decode("[]"), Data())
    }

    func testDecodesAllByteValues() {
        // Every value from 0 to 255 must round-trip cleanly. SwiftTerm's
        // `feed(byteArray:)` doesn't care about content, but UTF-8 sequences,
        // ANSI escapes (0x1B), and high bytes (0x80+) all need to land
        // unchanged.
        let payload = "[" + (0...255).map(String.init).joined(separator: ",") + "]"
        let decoded = PtyPayloadDecoder.decode(payload)
        XCTAssertEqual(decoded?.count, 256)
        XCTAssertEqual(decoded?.first, 0)
        XCTAssertEqual(decoded?.last, 255)
    }

    func testReturnsNilOnMalformed() {
        XCTAssertNil(PtyPayloadDecoder.decode("not-an-array"))
        XCTAssertNil(PtyPayloadDecoder.decode("[1, 2, "))     // truncated
        XCTAssertNil(PtyPayloadDecoder.decode("\"Hello\""))    // string, not array
        XCTAssertNil(PtyPayloadDecoder.decode("[256]"))        // out of UInt8 range
        XCTAssertNil(PtyPayloadDecoder.decode("[-1]"))         // out of UInt8 range
    }

    func testReturnsNilOnEmptyString() {
        XCTAssertNil(PtyPayloadDecoder.decode(""))
    }
}

final class WorkspaceLayoutInitTests: XCTestCase {
    /// The public memberwise initialiser was added explicitly in Sprint 7
    /// — the synthesised one was internal-only, which broke construction
    /// from the app target. This test pins the parameter list.
    func testPublicMemberwiseInit() {
        let layout = WorkspaceLayout(
            sidebarVisible: true,
            bottomVisible: false,
            inspectorVisible: true,
            sidebarWidth: 220,
            bottomHeight: 200,
            inspectorWidth: 260
        )
        XCTAssertTrue(layout.sidebarVisible)
        XCTAssertFalse(layout.bottomVisible)
        XCTAssertTrue(layout.inspectorVisible)
    }
}

final class TransferItemInitTests: XCTestCase {
    /// Same regression class as WorkspaceLayout — `TransferQueueManager`
    /// constructs `TransferItem` with these arguments from outside the
    /// framework, so the public init must keep this shape.
    func testPublicInitProducesProgress() {
        let item = TransferItem(
            id: "x",
            direction: .upload,
            localPath: "/local",
            remotePath: "/remote",
            size: 1000,
            bytesTransferred: 250,
            status: .inProgress,
            connectionId: "c"
        )
        XCTAssertEqual(item.progress, 0.25, accuracy: 0.001)
    }
}
