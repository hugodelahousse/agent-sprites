import AppKit
import Foundation
import os.log

struct AppRelease: Sendable, Equatable {
    let version: String
    let downloadURL: URL
    let releaseURL: URL
    let publishedAt: Date?
}

enum UpdateState: Equatable {
    case none
    case available(AppRelease)
    case downloading(progress: Double)
    case readyToInstall
    case installing
    case failed(String)

    var release: AppRelease? {
        if case .available(let release) = self {
            return release
        }
        return nil
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var updateState: UpdateState = .none
    @Published var isChecking = false
    @Published var lastCheckDate: Date?

    private let logger = Logger(subsystem: "com.agentsprites.app", category: "UpdateChecker")
    private let repo = "hugodelahousse/agent-sprites"
    private var checkTask: Task<Void, Never>?
    private var downloadDelegate: DownloadDelegate?

    /// Directory for staging downloaded updates
    private var updateStagingDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentSprites-update")
    }

    /// Path to the extracted app bundle ready to install
    private var stagedAppURL: URL {
        updateStagingDir.appendingPathComponent("AgentSprites.app")
    }

    /// Minimum interval between automatic checks (1 hour)
    private let minimumCheckInterval: TimeInterval = 3600

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The release associated with the current update flow, if any
    var currentRelease: AppRelease? {
        switch updateState {
        case .available(let release):
            return release
        default:
            return nil
        }
    }

    func checkOnLaunch() {
        cleanupStagingDirectory()

        checkTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }

            if let lastCheck = lastCheckDate,
               Date().timeIntervalSince(lastCheck) < minimumCheckInterval {
                logger.debug("Skipping update check, last check was recent")
                return
            }

            await checkForUpdates()
        }
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        logger.info("Checking for updates (current: \(self.currentVersion, privacy: .public))")

        do {
            let release = try await fetchLatestRelease()
            lastCheckDate = Date()

            if isNewer(release.version, than: currentVersion) {
                logger.info("Update available: \(release.version, privacy: .public)")
                updateState = .available(release)
            } else {
                logger.info("App is up to date")
                updateState = .none
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissUpdate() {
        updateState = .none
    }

    // MARK: - Download & Install

    /// Whether the app is running from a dev build (not a proper .app bundle)
    private var isDevBuild: Bool {
        let bundlePath = Bundle.main.bundlePath
        return bundlePath.contains(".build/") || !bundlePath.hasSuffix(".app")
    }

    func downloadAndInstall(release: AppRelease) {
        if isDevBuild {
            logger.info("Dev build detected, opening browser for download")
            NSWorkspace.shared.open(release.downloadURL)
            return
        }

        updateState = .downloading(progress: 0)
        logger.info("Starting download of v\(release.version, privacy: .public)")

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in
                self?.updateState = .downloading(progress: progress)
            }
        } onComplete: { [weak self] tempURL in
            Task { @MainActor in
                await self?.handleDownloadComplete(tempURL: tempURL)
            }
        } onError: { [weak self] error in
            Task { @MainActor in
                self?.logger.error("Download failed: \(error, privacy: .public)")
                self?.updateState = .failed(error)
            }
        }

        self.downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: release.downloadURL).resume()
    }

    private func handleDownloadComplete(tempURL: URL) async {
        logger.info("Download complete, extracting...")

        do {
            try prepareStaging()
            try await extractZip(at: tempURL)
            try verifyExtractedApp()

            logger.info("Extraction complete, installing...")
            installAndRelaunch()
        } catch {
            logger.error("Update installation failed: \(error.localizedDescription, privacy: .public)")
            updateState = .failed(error.localizedDescription)
        }
    }

    private func prepareStaging() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: updateStagingDir.path) {
            try fm.removeItem(at: updateStagingDir)
        }
        try fm.createDirectory(at: updateStagingDir, withIntermediateDirectories: true)
    }

    private func extractZip(at zipURL: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, updateStagingDir.path]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw UpdateError.extractionFailed
        }
    }

    private func verifyExtractedApp() throws {
        guard FileManager.default.fileExists(atPath: stagedAppURL.path) else {
            throw UpdateError.extractionFailed
        }
        logger.info("Verified extracted app at \(self.stagedAppURL.path, privacy: .public)")
    }

    func installAndRelaunch() {
        updateState = .installing
        let bundlePath = Bundle.main.bundlePath
        let appURL = URL(fileURLWithPath: bundlePath)

        logger.info("Installing update: replacing \(bundlePath, privacy: .public)")

        do {
            let fm = FileManager.default

            // Move the old app to trash so the user can recover if needed
            var trashedURL: NSURL?
            try fm.trashItem(at: appURL, resultingItemURL: &trashedURL)
            logger.info("Moved old app to trash")

            // Move the new app into place
            try fm.moveItem(at: stagedAppURL, to: appURL)
            logger.info("Installed new app bundle")

            // Clean up staging directory
            cleanupStagingDirectory()

            // Relaunch
            relaunchApp(at: appURL)
        } catch {
            logger.error("Install failed: \(error.localizedDescription, privacy: .public)")
            updateState = .failed("Installation failed: \(error.localizedDescription)")
        }
    }

    private func relaunchApp(at appURL: URL) {
        logger.info("Relaunching app from \(appURL.path, privacy: .public)")

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.logger.error("Failed to relaunch: \(error.localizedDescription, privacy: .public)")
                    self?.updateState = .failed("Failed to relaunch: \(error.localizedDescription)")
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func cleanupStagingDirectory() {
        let fm = FileManager.default
        if fm.fileExists(atPath: updateStagingDir.path) {
            try? fm.removeItem(at: updateStagingDir)
            logger.debug("Cleaned up update staging directory")
        }
    }

    // MARK: - GitHub API

    private func fetchLatestRelease() async throws -> AppRelease {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.networkError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String,
              let releaseURL = URL(string: htmlURL) else {
            throw UpdateError.parseError
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        var downloadURL = releaseURL
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String,
                   name.hasSuffix(".zip"),
                   let urlString = asset["browser_download_url"] as? String,
                   let assetURL = URL(string: urlString) {
                    downloadURL = assetURL
                    break
                }
            }
        }

        var publishedAt: Date?
        if let dateString = json["published_at"] as? String {
            let formatter = ISO8601DateFormatter()
            publishedAt = formatter.date(from: dateString)
        }

        return AppRelease(
            version: version,
            downloadURL: downloadURL,
            releaseURL: releaseURL,
            publishedAt: publishedAt
        )
    }

    /// Compare semantic versions. Returns true if `a` is newer than `b`.
    private func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(aParts.count, bParts.count) {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal > bVal { return true }
            if aVal < bVal { return false }
        }
        return false
    }
}

// MARK: - Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (URL) -> Void
    let onError: @Sendable (String) -> Void

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy the file before it gets cleaned up by the system
        let tempDir = FileManager.default.temporaryDirectory
        let savedURL = tempDir.appendingPathComponent("AgentSprites-download.zip")
        try? FileManager.default.removeItem(at: savedURL)

        do {
            try FileManager.default.copyItem(at: location, to: savedURL)
            onComplete(savedURL)
        } catch {
            onError("Failed to save download: \(error.localizedDescription)")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onError(error.localizedDescription)
        }
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case networkError
    case parseError
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .networkError: return "Failed to reach GitHub"
        case .parseError: return "Failed to parse release info"
        case .extractionFailed: return "Failed to extract update"
        }
    }
}
