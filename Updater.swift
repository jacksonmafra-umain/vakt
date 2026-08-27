import Foundation
import AppKit

/// Checks GitHub for a newer release, downloads it, and swaps it in.
///
/// This is the only network code in VAKT, and it exists on request. It talks to
/// exactly one host, reads a public releases feed, sends no identifying
/// information beyond what any HTTPS request carries, and can be switched off in
/// Settings. The privacy claim elsewhere — that no frames leave the machine —
/// still holds: nothing about what the camera sees is ever sent anywhere.
///
/// Installing is deliberately *not* silent by default. This build is signed
/// ad-hoc, with no Developer ID, so a downloaded bundle cannot be tied
/// cryptographically to the same author as the running one: `codesign` can say
/// "intact", never "same hands". Replacing the binary that guards your Mac on the
/// strength of "the API said so" is a supply-chain hole, so the install step is
/// gated behind Touch ID unless you explicitly opt into automatic installs.
@MainActor
final class Updater: ObservableObject {

    /// Shared because two places need the same instance: the menu, which renders
    /// its state, and the app delegate, which drives the polling. The delegate is
    /// the only reliable place for launch work — a `.task` on a `MenuBarExtra`
    /// label silently never runs once the label carries extra modifiers.
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let tag: String
        let asset: URL
        let page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case downloading(Release)
        case readyToInstall(Release, app: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let repository = "jacksonmafra-umain/vakt"
    private let session = URLSession(configuration: .ephemeral)
    private var lastCheck: Date?

    /// Mirrors `Policy.installUpdatesAutomatically`. When set, a finished
    /// download installs itself and VAKT relaunches — no click, no Touch ID.
    var installsAutomatically = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Checking

    /// Called on launch and once a day. `force` ignores the interval.
    func checkIfDue(interval: TimeInterval, force: Bool = false) async {
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < interval { return }
        await check()
    }

    func check() async {
        if case .downloading = state { return }
        state = .checking
        lastCheck = Date()

        do {
            let release = try await latestRelease()
            if Updater.isNewer(release.version, than: currentVersion) {
                state = .available(release)
                EventLog.shared.record("update.available", "\(currentVersion) → \(release.version)")
            } else {
                state = .upToDate(checkedAt: Date())
            }
        } catch {
            state = .failed(error.localizedDescription)
            EventLog.shared.record("update.checkFailed", error.localizedDescription)
        }
    }

    private func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VAKT/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.noAsset
        }
        return Release(version: payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                       tag: payload.tag_name,
                       asset: asset.browser_download_url,
                       page: payload.html_url)
    }

    /// Numeric, component-wise. "0.2.10" is newer than "0.2.9", which string
    /// comparison gets wrong.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Downloading

    func download(_ release: Release) async {
        state = .downloading(release)
        do {
            let app = try await fetchAndUnpack(release)
            state = .readyToInstall(release, app: app)
            EventLog.shared.record("update.downloaded", "\(release.version) ready to install.")
            if installsAutomatically {
                try install(release, from: app)
            }
        } catch {
            state = .failed(error.localizedDescription)
            EventLog.shared.record("update.downloadFailed", error.localizedDescription)
        }
    }

    private func fetchAndUnpack(_ release: Release) async throws -> URL {
        guard release.asset.scheme == "https",
              let host = release.asset.host,
              host.hasSuffix("github.com") || host.hasSuffix("githubusercontent.com") else {
            throw UpdateError.untrustedAsset
        }

        let (file, response) = try await session.download(from: release.asset)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vakt-update-\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let zip = work.appendingPathComponent("release.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        try Updater.shell("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        guard let app = Updater.findApp(in: work) else { throw UpdateError.noAppInArchive }

        // Intact, and actually the version it claims to be. `codesign` cannot
        // prove authorship for an ad-hoc bundle, so this is a sanity check on the
        // download, not a trust decision.
        try Updater.shell("/usr/bin/codesign", ["--verify", "--strict", app.path])

        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let shipped = info["CFBundleShortVersionString"] as? String,
              shipped == release.version else {
            throw UpdateError.versionMismatch
        }
        return app
    }

    private static func findApp(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil) else { return nil }
        if let app = entries.first(where: { $0.pathExtension == "app" }) { return app }
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let nested = findApp(in: entry) { return nested }
        }
        return nil
    }

    // MARK: - Installing

    /// Swaps the bundle and relaunches. VAKT cannot overwrite itself while it is
    /// running, so the work is handed to a detached script that waits for this
    /// process to exit first — and that unloads the LaunchAgent before the swap,
    /// because `KeepAlive` would otherwise relaunch the old bundle mid-copy.
    func install(_ release: Release, from newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vakt-install-\(release.version).sh")

        let agent = "\(NSHomeDirectory())/Library/LaunchAgents/com.jacksonmafra.vakt.plist"
        let body = """
        #!/bin/bash
        set -u
        pid=\(ProcessInfo.processInfo.processIdentifier)
        launchctl bootout "gui/$(id -u)/com.jacksonmafra.vakt" 2>/dev/null
        for _ in $(seq 1 100); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        /usr/bin/ditto "\(newApp.path)" "\(target.path).new" || exit 1
        /bin/rm -rf "\(target.path)"
        /bin/mv "\(target.path).new" "\(target.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
        if [ -f "\(agent)" ]; then
            launchctl bootstrap "gui/$(id -u)" "\(agent)"
        else
            /usr/bin/open "\(target.path)"
        fi
        /bin/rm -rf "\(newApp.deletingLastPathComponent().path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        EventLog.shared.record("update.installing", "\(currentVersion) → \(release.version)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        try process.run()

        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    @discardableResult
    private static func shell(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.tool(tool, String(data: data, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum UpdateError: LocalizedError {
    case http(Int)
    case noAsset
    case noAppInArchive
    case untrustedAsset
    case versionMismatch
    case tool(String, String)

    var errorDescription: String? {
        switch self {
        case .http(let code):        return "GitHub replied \(code)."
        case .noAsset:               return "That release has no downloadable archive."
        case .noAppInArchive:        return "The archive contains no application."
        case .untrustedAsset:        return "The download URL is not on GitHub. Refusing it."
        case .versionMismatch:       return "The downloaded app is not the version the release claims."
        case .tool(let name, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name) failed. \(detail.isEmpty ? "" : detail)"
        }
    }
}
