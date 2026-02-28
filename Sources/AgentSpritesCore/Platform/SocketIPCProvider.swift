import Foundation

/// IPC message envelope sent over the socket
struct IPCMessage: Codable {
    enum MessageType: String, Codable {
        case sessionEvent
        case sessionEnd
    }

    let type: MessageType
    let eventJSON: String?    // For sessionEvent: JSON-encoded SessionEvent
    let sessionId: String?    // For sessionEnd: session ID to remove
}

/// Cross-platform IPC provider using Unix domain sockets (macOS/Linux) or named pipes (Windows).
/// The CLI connects as a client and writes messages. The App listens as a server.
public final class SocketIPCProvider: IPCProvider, @unchecked Sendable {
    private let socketPath: String
    private var serverSocket: Int32 = -1
    private var isListening = false
    private var listenerThread: Thread?
    private var onSessionEventCallback: (@Sendable (SessionEvent) -> Void)?
    private var onSessionEndCallback: (@Sendable (String) -> Void)?

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? Self.defaultSocketPath
    }

    /// Default socket path in Application Support
    public static var defaultSocketPath: String {
        AgentSpritesConstants.applicationSupportDirectory
            .appendingPathComponent("ipc.sock").path
    }

    // MARK: - Client (CLI side)

    public func postSessionEvent(_ event: SessionEvent) throws {
        guard let eventJSON = event.toJSONString() else {
            throw SocketIPCError.encodingFailed
        }
        let message = IPCMessage(type: .sessionEvent, eventJSON: eventJSON, sessionId: nil)
        try sendMessage(message)
    }

    public func postSessionEnd(sessionId: String) throws {
        let message = IPCMessage(type: .sessionEnd, eventJSON: nil, sessionId: sessionId)
        try sendMessage(message)
    }

    private func sendMessage(_ message: IPCMessage) throws {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(message),
              var jsonString = String(data: data, encoding: .utf8) else {
            throw SocketIPCError.encodingFailed
        }
        jsonString += "\n"

        #if canImport(Darwin)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let sock = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard sock >= 0 else {
            throw SocketIPCError.connectionFailed("Failed to create socket")
        }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketIPCError.connectionFailed("Socket path too long")
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                bound[i] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Foundation.connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            throw SocketIPCError.connectionFailed("Failed to connect to \(socketPath): errno \(errno)")
        }

        guard let messageData = jsonString.data(using: .utf8) else {
            throw SocketIPCError.encodingFailed
        }

        _ = messageData.withUnsafeBytes { buffer in
            send(sock, buffer.baseAddress!, buffer.count, 0)
        }
    }

    // MARK: - Server (App side)

    public func observeEvents(
        onSessionEvent: @escaping @Sendable (SessionEvent) -> Void,
        onSessionEnd: @escaping @Sendable (String) -> Void
    ) {
        self.onSessionEventCallback = onSessionEvent
        self.onSessionEndCallback = onSessionEnd

        // Ensure socket directory exists
        let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Remove stale socket file
        unlink(socketPath)

        startListening()
    }

    public func stopObserving() {
        isListening = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
        onSessionEventCallback = nil
        onSessionEndCallback = nil
    }

    private func startListening() {
        #if canImport(Darwin)
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        serverSocket = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard serverSocket >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                bound[i] = byte
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else { return }
        guard listen(serverSocket, 5) == 0 else { return }

        isListening = true

        // Accept connections on a background thread
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "AgentSprites-IPC-Listener"
        thread.qualityOfService = .utility
        thread.start()
        listenerThread = thread
    }

    private func acceptLoop() {
        while isListening {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSock >= 0 else {
                if !isListening { break }
                continue
            }

            handleClient(clientSock)
            close(clientSock)
        }
    }

    private func handleClient(_ sock: Int32) {
        var buffer = Data()
        var readBuffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = recv(sock, &readBuffer, readBuffer.count, 0)
            guard bytesRead > 0 else { break }
            buffer.append(contentsOf: readBuffer[0..<bytesRead])
        }

        // Process newline-delimited messages
        guard let content = String(data: buffer, encoding: .utf8) else { return }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            processMessage(line)
        }
    }

    private func processMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let message = try? JSONDecoder().decode(IPCMessage.self, from: data) else {
            return
        }

        switch message.type {
        case .sessionEvent:
            guard let eventJSON = message.eventJSON,
                  let event = SessionEvent.fromJSONString(eventJSON) else {
                return
            }
            onSessionEventCallback?(event)

        case .sessionEnd:
            guard let sessionId = message.sessionId else { return }
            onSessionEndCallback?(sessionId)
        }
    }

    deinit {
        stopObserving()
    }
}

public enum SocketIPCError: Error {
    case encodingFailed
    case connectionFailed(String)
}
