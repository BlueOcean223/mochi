import AppKit
import MochiCore
import Security

/// 检查更新、下载新版本、替换自己、重启。版本发在 GitHub Release 上（推 v 开头的标签时 GitHub Actions 发布，附 Mochi-<版本号>.zip）。
/// 只连 api.github.com 和附件的下载地址，请求里没有别的内容；用 ephemeral 会话，不在磁盘上留 cookie 和缓存。
///
/// 新版本要和正在跑的这个满足同一个签名要求（designated requirement）才装：发布版都用同一张证书签，
/// 辅助功能权限认的也是它。ad-hoc 签名的构建要求里是自己的哈希，任何新版本都对不上，所以不会装。
@MainActor
@Observable
final class Updater {
    enum Status {
        case idle
        case checking
        case upToDate
        case downloading
        case installing
        case failed(String)
    }

    /// 比正在用的新、带着打包好的应用的那个 Release。
    private(set) var latest: Release?
    private(set) var status = Status.idle
    let currentVersion: String

    /// 发现新版本、新版本没了的时候调（菜单栏菜单跟着变）。
    @ObservationIgnored var changed: (() -> Void)?
    /// 跑调试脚本时不重启。
    @ObservationIgnored var isQuiet = false

    private let settings: Settings
    /// Info.plist 里的 MochiUpdateRepository，比如 BlueOcean223/mochi。没有就不检查更新。
    private let repository: String?
    private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var timer: Timer?

    /// 自动检查的间隔。
    static let interval: TimeInterval = 24 * 3600

    init(settings: Settings) {
        self.settings = settings
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        repository = Bundle.main.object(forInfoDictionaryKey: "MochiUpdateRepository") as? String
    }

    var isAvailable: Bool {
        repository != nil || Self.localFeed != nil
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    var lastChecked: Date? { settings.lastUpdateCheck }

    /// 每小时看一眼离上次检查够不够 24 小时。启动后等 30 秒再看第一次：开机启动时网络可能还没好。
    func start() {
        guard isAvailable, timer == nil else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task {
            try? await Task.sleep(for: .seconds(30))
            checkIfDue()
        }
    }

    private func checkIfDue() {
        guard settings.checksForUpdates, !isBusy else { return }
        if let last = settings.lastUpdateCheck, Date.now.timeIntervalSince(last) < Self.interval - 600 { return }
        Task { await check(userInitiated: false) }
    }

    /// 自动检查失败时不提示（没联网、GitHub 一时连不上都很常见），下次再查；点「检查更新」时才说为什么。
    func check(userInitiated: Bool) async {
        guard isAvailable, !isBusy else { return }
        status = .checking
        do {
            let release = try Release.decode(try await fetchLatest())
            settings.lastUpdateCheck = .now
            let current = AppVersion(currentVersion)
            if let version = release.version, let current, version > current, release.archive != nil {
                latest = release
                status = .idle
                log.notice("update available: \(version.description, privacy: .public)")
            } else {
                latest = nil
                status = .upToDate
            }
        } catch UpdateError.notPublished {
            settings.lastUpdateCheck = .now
            latest = nil
            status = userInitiated ? .failed("GitHub 上还没有发布过版本") : .idle
        } catch {
            log.error("update check failed: \(error, privacy: .public)")
            status = userInitiated ? .failed("没查成：\(Self.describe(error))") : .idle
        }
        changed?()
    }

    private func fetchLatest() async throws -> Data {
        #if DEBUG
        if let feed = Self.localFeed { return try Data(contentsOf: feed) }
        #endif
        guard let repository, let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.notPublished
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Mochi/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 仓库里还没有正式发布的版本时，这个接口返回 404。
        if code == 404 { throw UpdateError.notPublished }
        guard code == 200 else { throw UpdateError.http(code) }
        return data
    }

    // MARK: - 安装

    /// 下载到和应用同一个卷上的临时目录，解压，核对签名和版本，原子地换掉现在的应用，再重启。
    func install() async {
        guard let release = latest, let archive = release.archive, !isBusy else { return }
        let bundle = Bundle.main.bundleURL
        // 从下载文件夹直接打开、没挪过的应用，系统在一个只读的随机位置运行它（App Translocation），换不了。
        if bundle.path.contains("/AppTranslocation/") {
            status = .failed("先把 Mochi 拖进「应用程序」，从那里打开再更新")
            return
        }
        if Self.isAdHoc {
            status = .failed("这个 Mochi 是 ad-hoc 签名的，新版本的签名和它对不上，要自己下载替换")
            return
        }
        status = .downloading
        var work: URL?
        do {
            let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                        appropriateFor: bundle, create: true)
            work = directory
            let zip = directory.appending(path: archive.name)
            try await download(archive.downloadURL, to: zip)
            status = .installing
            let unpacked = directory.appending(path: "unpacked", directoryHint: .isDirectory)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let app = unpacked.appending(path: "Mochi.app", directoryHint: .isDirectory)
            try Self.verify(app, version: release.version)
            _ = try FileManager.default.replaceItemAt(bundle, withItemAt: app)
            try? FileManager.default.removeItem(at: directory)
            log.notice("updated to \(release.tag, privacy: .public)")
            relaunch(bundle)
        } catch {
            if let work { try? FileManager.default.removeItem(at: work) }
            log.error("update failed: \(error, privacy: .public)")
            status = .failed("没更新成：\(Self.describe(error))")
        }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: destination)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Mochi/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await session.download(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.http(code) }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    /// 新的应用要和正在跑的满足同一个签名要求，bundle id 一样，版本号和 Release 的一样。
    private static func verify(_ app: URL, version: AppVersion?) throws {
        var current: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &current) == errSecSuccess, let current,
              SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError.signature
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else { throw UpdateError.signature }
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError.notMochi }
        guard let version, (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == version else {
            throw UpdateError.versionMismatch
        }
    }

    /// ad-hoc 签名的构建（没有「Mochi Development」证书时 scripts/bundle.sh 这么签）要求里写的是自己的哈希。
    private static var isAdHoc: Bool {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else { return true }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    /// 等这个进程退出以后再打开新的：退出前打开，系统会把已经在跑的这个提到前面，不会启动新的。
    private func relaunch(_ bundle: URL) {
        guard !isQuiet else {
            print("updater: 换好了，不重启（调试脚本）")
            status = .idle
            return
        }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        do {
            try process.run()
        } catch {
            log.error("relaunch failed: \(error, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.unpack(process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.http(let code): "GitHub 返回 \(code)"
        case UpdateError.signature: "新版本的签名和现在这个对不上，没有安装"
        case UpdateError.notMochi: "下载的不是 Mochi"
        case UpdateError.versionMismatch: "下载的版本号和 Release 的对不上"
        case UpdateError.unpack: "解压失败"
        case let error as CocoaError where error.code == .fileWriteNoPermission:
            "没有权限替换 \(Bundle.main.bundleURL.path)"
        default: error.localizedDescription
        }
    }

    #if DEBUG
    /// 调试时用本地的 JSON 代替 GitHub 的接口（附件地址可以写 file://）。
    private static var localFeed: URL? {
        ProcessInfo.processInfo.environment["MOCHI_UPDATE_FEED"].map { URL(filePath: $0) }
    }
    #else
    private static var localFeed: URL? { nil }
    #endif
}

enum UpdateError: Error {
    case notPublished
    case http(Int)
    case signature
    case notMochi
    case versionMismatch
    case unpack(Int32)
}
