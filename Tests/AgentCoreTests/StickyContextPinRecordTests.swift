import XCTest
@testable import AgentCore

final class StickyContextPinRecordTests: XCTestCase {
    func testConversationRoundTripsStickyPins() throws {
        var convo = Conversation(title: "pins")
        convo.stickyContextPins = [
            StickyContextPinRecord(kind: "file", path: "/a/B.swift", displayName: "B.swift"),
            StickyContextPinRecord(kind: "symbol", path: "/a/B.swift", displayName: "foo", symbolName: "foo"),
        ]
        let data = try JSONEncoder().encode(convo)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded.stickyContextPins.count, 2)
        XCTAssertEqual(decoded.stickyContextPins[0].path, "/a/B.swift")
        XCTAssertEqual(decoded.stickyContextPins[1].symbolName, "foo")
    }

    func testNotificationsDefaultOn() {
        XCTAssertTrue(AppSettings().notificationsEnabled)
    }
}
