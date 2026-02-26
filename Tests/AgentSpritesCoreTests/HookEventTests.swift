import XCTest
@testable import AgentSpritesCore

final class HookEventTests: XCTestCase {

    // MARK: - Basic Parsing Tests

    func testParseUserPromptSubmit() throws {
        let json = """
        {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "abc-123",
            "cwd": "/Users/test/project"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "UserPromptSubmit")
        XCTAssertEqual(event.sessionId, "abc-123")
        XCTAssertEqual(event.cwd, "/Users/test/project")
        XCTAssertEqual(event.determineStatus(), .working)
    }

    func testParseSessionStart() throws {
        let json = """
        {
            "hook_event_name": "SessionStart",
            "session_id": "session-456",
            "cwd": "/home/user/code"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "SessionStart")
        XCTAssertEqual(event.determineStatus(), .idle)
    }

    func testParseStop() throws {
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "session-789",
            "cwd": "/tmp"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "Stop")
        XCTAssertEqual(event.determineStatus(), .done)
    }

    // MARK: - Permission Request with Object tool_input

    func testParsePermissionRequestWithObjectToolInput() throws {
        let json = """
        {
            "session_id": "9f72ca7a-ddff-414c-bed7-1d44bb60e4b6",
            "transcript_path": "/Users/hugo/.claude/projects/test.jsonl",
            "cwd": "/Users/hugo/projects/agent-sprites",
            "permission_mode": "default",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {
                "command": "ls -la",
                "description": "List files"
            }
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "PermissionRequest")
        XCTAssertEqual(event.sessionId, "9f72ca7a-ddff-414c-bed7-1d44bb60e4b6")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertNotNil(event.toolInput)
        XCTAssertTrue(event.toolInput?.contains("ls -la") ?? false)
        XCTAssertEqual(event.determineStatus(), .waitingForPermission)
    }

    func testParsePermissionRequestWithStringToolInput() throws {
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "test-session",
            "cwd": "/tmp",
            "tool_name": "Read",
            "tool_input": "some string input"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "PermissionRequest")
        XCTAssertEqual(event.toolInput, "some string input")
    }

    func testParsePermissionRequestWithNestedObjectToolInput() throws {
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "test-session",
            "cwd": "/tmp",
            "tool_name": "Task",
            "tool_input": {
                "prompt": "Do something",
                "subagent_type": "Explore",
                "options": {
                    "nested": true,
                    "count": 42
                }
            }
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "PermissionRequest")
        XCTAssertNotNil(event.toolInput)
        // The tool_input should be serialized as JSON string
        XCTAssertTrue(event.toolInput?.contains("Do something") ?? false)
        XCTAssertTrue(event.toolInput?.contains("Explore") ?? false)
    }

    // MARK: - Notification Tests

    func testParseNotificationElicitationDialog() throws {
        let json = """
        {
            "hook_event_name": "Notification",
            "session_id": "notif-123",
            "cwd": "/test",
            "notification_type": "elicitation_dialog",
            "message": "Please answer the question"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "Notification")
        XCTAssertEqual(event.notificationType, "elicitation_dialog")
        XCTAssertEqual(event.message, "Please answer the question")
        XCTAssertEqual(event.determineStatus(), .waitingForInput)
    }

    func testParseNotificationPermissionPrompt() throws {
        let json = """
        {
            "hook_event_name": "Notification",
            "session_id": "notif-456",
            "cwd": "/test",
            "notification_type": "permission_prompt"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.determineStatus(), .waitingForPermission)
    }

    func testParseNotificationIdlePrompt() throws {
        let json = """
        {
            "hook_event_name": "Notification",
            "session_id": "notif-789",
            "cwd": "/test",
            "notification_type": "idle_prompt"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.determineStatus(), .idle)
    }

    // MARK: - Error Handling Tests

    func testParsePostToolUseFailure() throws {
        let json = """
        {
            "hook_event_name": "PostToolUseFailure",
            "session_id": "error-session",
            "cwd": "/test",
            "tool_name": "Bash",
            "error": "Command failed with exit code 1"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "PostToolUseFailure")
        XCTAssertEqual(event.error, "Command failed with exit code 1")
        XCTAssertEqual(event.determineStatus(), .error)
    }

    // MARK: - Missing Event Name Fallback

    func testParseMissingEventNameDefaultsToUnknown() throws {
        let json = """
        {
            "session_id": "no-event-name",
            "cwd": "/test"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "Unknown")
        XCTAssertEqual(event.determineStatus(), .working)
    }

    // MARK: - Session End

    func testParseSessionEnd() throws {
        let json = """
        {
            "hook_event_name": "SessionEnd",
            "session_id": "ending-session",
            "cwd": "/test"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "SessionEnd")
        XCTAssertTrue(event.shouldRemoveSession)
    }

    // MARK: - Subagent Events

    func testParseSubagentStart() throws {
        let json = """
        {
            "hook_event_name": "SubagentStart",
            "session_id": "subagent-session",
            "cwd": "/test"
        }
        """

        let event = try HookEvent.parse(from: json)

        XCTAssertEqual(event.hookEventName, "SubagentStart")
        XCTAssertEqual(event.determineStatus(), .working)
    }

    // MARK: - Invalid JSON

    func testParseInvalidJSONThrows() {
        let json = "not valid json"

        XCTAssertThrowsError(try HookEvent.parse(from: json))
    }

    func testParseMissingRequiredFieldsThrows() {
        let json = """
        {
            "hook_event_name": "UserPromptSubmit"
        }
        """

        XCTAssertThrowsError(try HookEvent.parse(from: json))
    }
}
