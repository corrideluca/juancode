import XCTest
@testable import JuancodeServer

/// Decode coverage for the WS wire protocol (juancode-iqi adds `adoptExternal`).
/// Keeps the flat-JSON shape in sync with the two `protocol.ts` files.
final class WireProtocolTests: XCTestCase {
    private func decode(_ json: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
    }

    func testDecodesAdoptExternal() throws {
        let json = """
        {"type":"adoptExternal","provider":"claude","cliSessionId":"conv-7",
         "cwd":"/Users/me/project","startMs":1700000000000,"cols":120,"rows":40}
        """
        guard case let .adoptExternal(provider, cliSessionId, cwd, startMs, cols, rows) = try decode(json) else {
            return XCTFail("expected .adoptExternal")
        }
        XCTAssertEqual(provider, "claude")
        XCTAssertEqual(cliSessionId, "conv-7")
        XCTAssertEqual(cwd, "/Users/me/project")
        XCTAssertEqual(startMs, 1_700_000_000_000)
        XCTAssertEqual(cols, 120)
        XCTAssertEqual(rows, 40)
    }

    func testUnknownTypeStillThrows() {
        XCTAssertThrowsError(try decode(#"{"type":"bogus"}"#))
    }
}
