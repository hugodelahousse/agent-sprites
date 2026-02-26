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
            ("SubagentStart", .working)
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

    // MARK: - HookEvent Alternative Key Handling Tests
    //
    // Claude Code officially uses "hook_event_name", but we defensively handle
    // alternative key names in case of format variations:
    // - "event_name" (potential older format)
    // - "hookEventName" (camelCase variant)
    // - "event" (abbreviated form)
    //
    // The custom Codable init(from:) tries each key in priority order.

    func testParsesOfficialHookEventNameKey() throws {
        let json = """
        {"hook_event_name": "UserPromptSubmit", "session_id": "test-456", "cwd": "/tmp/test"}
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.hookEventName, "UserPromptSubmit")
        XCTAssertEqual(event.sessionId, "test-456")
    }

    func testParsesEventNameKey() throws {
        let json = """
        {"event_name": "Stop", "session_id": "s1", "cwd": "/home/user"}
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.hookEventName, "Stop")
    }

    func testParsesCamelCaseHookEventName() throws {
        let json = """
        {"hookEventName": "SessionStart", "session_id": "s2", "cwd": "/tmp"}
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.hookEventName, "SessionStart")
    }

    func testParsesShortEventKey() throws {
        let json = """
        {"event": "PermissionRequest", "session_id": "s3", "cwd": "/var"}
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.hookEventName, "PermissionRequest")
    }

    func testDefaultsToUnknownWhenNoEventKey() throws {
        let json = """
        {"some_other_key": "value", "session_id": "s4", "cwd": "/tmp"}
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.hookEventName, "Unknown")
    }

    func testRequiresSessionIdAndCwd() throws {
        let json = """
        {"hook_event_name": "Stop"}
        """
        XCTAssertThrowsError(try HookEvent.parse(from: json))
    }

    func testParsesAllOptionalFields() throws {
        let json = """
        {
            "event_name": "Notification",
            "session_id": "test-789",
            "cwd": "/projects/app",
            "tool_name": "Bash",
            "tool_input": "ls -la",
            "notification_type": "permission_prompt",
            "message": "Allow access?",
            "transcript_path": "/tmp/transcript.json"
        }
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.hookEventName, "Notification")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolInput, "ls -la")
        XCTAssertEqual(event.notificationType, "permission_prompt")
        XCTAssertEqual(event.message, "Allow access?")
        XCTAssertEqual(event.transcriptPath, "/tmp/transcript.json")
    }

    func testKeyPriorityOrder() throws {
        // When multiple event name keys are present, hook_event_name takes priority
        let json = """
        {"hook_event_name": "Official", "event_name": "Alternative", "session_id": "s5", "cwd": "/tmp"}
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.hookEventName, "Official")
    }

    // MARK: - Notification Type Status Determination Tests
    //
    // Claude Code sends different notification_type values that map to different statuses.
    // This is critical for showing the correct UI state (color, animation) to the user.

    func testNotificationElicitationDialogMapsToWaitingForInput() throws {
        let event = HookEvent(
            hookEventName: "Notification",
            sessionId: "test",
            cwd: "/tmp",
            notificationType: "elicitation_dialog"
        )
        XCTAssertEqual(event.determineStatus(), .waitingForInput)
    }

    func testNotificationPermissionPromptMapsToWaitingForPermission() throws {
        let event = HookEvent(
            hookEventName: "Notification",
            sessionId: "test",
            cwd: "/tmp",
            notificationType: "permission_prompt"
        )
        XCTAssertEqual(event.determineStatus(), .waitingForPermission)
    }

    func testNotificationIdlePromptMapsToIdle() throws {
        let event = HookEvent(
            hookEventName: "Notification",
            sessionId: "test",
            cwd: "/tmp",
            notificationType: "idle_prompt"
        )
        XCTAssertEqual(event.determineStatus(), .idle)
    }

    func testNotificationAuthSuccessMapsToWorking() throws {
        let event = HookEvent(
            hookEventName: "Notification",
            sessionId: "test",
            cwd: "/tmp",
            notificationType: "auth_success"
        )
        XCTAssertEqual(event.determineStatus(), .working)
    }

    func testNotificationUnknownTypeDefaultsToWaitingForInput() throws {
        let event = HookEvent(
            hookEventName: "Notification",
            sessionId: "test",
            cwd: "/tmp",
            notificationType: "some_unknown_type"
        )
        XCTAssertEqual(event.determineStatus(), .waitingForInput)
    }

    func testNotificationWithoutTypeMapsToWaitingForInput() throws {
        let event = HookEvent(
            hookEventName: "Notification",
            sessionId: "test",
            cwd: "/tmp",
            notificationType: nil
        )
        XCTAssertEqual(event.determineStatus(), .waitingForInput)
    }

    func testNotificationTypePassedThroughParsing() throws {
        let json = """
        {
            "hook_event_name": "Notification",
            "session_id": "test-123",
            "cwd": "/tmp",
            "notification_type": "permission_prompt"
        }
        """
        let event = try HookEvent.parse(from: json)
        XCTAssertEqual(event.notificationType, "permission_prompt")
        XCTAssertEqual(event.determineStatus(), .waitingForPermission)
    }
}
