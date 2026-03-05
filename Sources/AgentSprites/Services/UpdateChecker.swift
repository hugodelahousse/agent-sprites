import Foundation
import os.log

struct AppRelease: Sendable {
    let version: String
    let downloadURL: URL
    let releaseURL: URL
    let publishedAt: Date?
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var availableUpdate: AppRelease?
    @Published var isChecking = false
    @Published var lastCheckDate: Date?

    private let logger = Logger(subsystem: "com.agentsprites.app", category: "UpdateChecker")
    private let repo = "hugodelahousse/agent-sprites"
    private var checkTask: Task<Void, Never>?

    /// Minimum interval between automatic checks (1 hour)
    private let minimumCheckInterval: TimeInterval = 3600

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkOnLaunch() {
        // Delay initial check by 5 seconds to not slow down launch
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }

            // Only check if enough time has passed since last check
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
                availableUpdate = release
            } else {
                logger.info("App is up to date")
                availableUpdate = nil
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissUpdate() {
        availableUpdate = nil
    }

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

        // Strip leading "v" from tag
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        // Find the zip asset
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

enum UpdateError: LocalizedError {
    case networkError
    case parseError

    var errorDescription: String? {
        switch self {
        case .networkError: return "Failed to reach GitHub"
        case .parseError: return "Failed to parse release info"
        }
    }
}
