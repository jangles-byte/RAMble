import Foundation
import AppKit

/// One-click updates from GitHub releases.
///
/// Flow: query `releases/latest` → compare the tag against the running
/// bundle's version → download the `RAMble.app.zip` asset → unzip with
/// `ditto` → swap the installed app → relaunch.
@MainActor
public final class UpdateChecker: ObservableObject {
    public enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case installing
        case failed(String)
        case installed          // relaunch imminent
    }

    @Published public private(set) var status: Status = .idle

    public static let shared = UpdateChecker()

    private let releasesURL =
        URL(string: "https://api.github.com/repos/jangles-byte/RAMble/releases/latest")!
    private var downloadURL: URL?

    public var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when running from a proper .app bundle (self-update possible).
    public var canSelfUpdate: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    public func check() {
        status = .checking
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.status = .failed(error?.localizedDescription
                                          ?? "No release found — check back later.")
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = json["assets"] as? [[String: Any]] ?? []
                self.downloadURL = assets
                    .first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                    .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }

                if Self.isNewer(latest, than: self.currentVersion), self.downloadURL != nil {
                    self.status = .available(version: latest)
                } else {
                    self.status = .upToDate
                }
            }
        }.resume()
    }

    public func downloadAndInstall() {
        guard case .available = status, let url = downloadURL, canSelfUpdate else { return }
        status = .downloading
        URLSession.shared.downloadTask(with: url) { [weak self] tempFile, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let tempFile else {
                    self.status = .failed(error?.localizedDescription ?? "Download failed.")
                    return
                }
                self.install(zipAt: tempFile)
            }
        }.resume()
    }

    private func install(zipAt zip: URL) {
        status = .installing
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("ramble-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", "-xk", zip.path, staging.path)
            guard let newApp = try fm.contentsOfDirectory(at: staging,
                    includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                status = .failed("Archive did not contain an app.")
                return
            }
            let installedApp = URL(fileURLWithPath: Bundle.main.bundlePath)
            let backup = staging.appendingPathComponent("previous.app")
            try fm.moveItem(at: installedApp, to: backup)
            do {
                try fm.moveItem(at: newApp, to: installedApp)
            } catch {
                try? fm.moveItem(at: backup, to: installedApp)  // roll back
                throw error
            }
            status = .installed
            relaunch(installedApp)
        } catch {
            status = .failed("Install failed: \(error.localizedDescription)")
        }
    }

    private func relaunch(_ app: URL) {
        // Spawn the new copy after this process exits.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(app.path)\""]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    private func run(_ launchPath: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "UpdateChecker", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(launchPath) failed"])
        }
    }

    /// Semantic-ish version compare ("1.2.0" vs "1.10" handled numerically).
    nonisolated public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
