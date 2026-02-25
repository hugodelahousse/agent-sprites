import XCTest
@testable import AgentSpritesCore

final class SessionStateTests: XCTestCase {
    func testSessionStatusColorName() {
        XCTAssertEqual(SessionStatus.idle.colorName, "gray")
        XCTAssertEqual(SessionStatus.working.colorName, "blue")
        XCTAssertEqual(SessionStatus.waitingForInput.colorName, "yellow")
        XCTAssertEqual(SessionStatus.waitingForPermission.colorName, "red")
        XCTAssertEqual(SessionStatus.error.colorName, "red")
        XCTAssertEqual(SessionStatus.done.colorName, "green")
    }

    func testSessionStateDisplayName() {
        let session = SessionState(
            id: "test-123",
            status: .working,
            workingDirectory: "/Users/test/projects/myproject"
        )
        XCTAssertEqual(session.displayName, "myproject")
    }

    func testHookEventParsing() throws {
        let json = """
        {
            "hook_event_name": "SessionStart",
            "session_id": "abc-123",
            "cwd": "/tmp/test"
        }
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.hookEventName, "SessionStart")
        XCTAssertEqual(event.sessionId, "abc-123")
        XCTAssertEqual(event.cwd, "/tmp/test")
    }

    func testHookEventDetermineStatus() throws {
        let testCases: [(String, SessionStatus)] = [
            ("SessionStart", .idle),
            ("UserPromptSubmit", .working),
            ("Stop", .done),
            ("Notification", .waitingForInput),
            ("PermissionRequest", .waitingForPermission),
            ("PostToolUseFailure", .error),
            ("SubagentStart", .working),
        ]

        for (eventName, expectedStatus) in testCases {
            let event = HookEvent(
                hookEventName: eventName,
                sessionId: "test",
                cwd: "/tmp"
            )
            XCTAssertEqual(event.determineStatus(), expectedStatus, "Event \(eventName) should map to \(expectedStatus)")
        }
    }

    func testSessionStoreActiveSessions() {
        var store = SessionStore()
        store.sessions["a"] = SessionState(id: "a", status: .working, workingDirectory: "/a", lastUpdated: Date())
        store.sessions["b"] = SessionState(id: "b", status: .idle, workingDirectory: "/b", lastUpdated: Date().addingTimeInterval(-100))

        let active = store.activeSessions
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(active.first?.id, "a") // Most recent first
    }
}
