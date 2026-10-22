import AppKit
import MochiCore

/// 盯着剪切板，有新的复制就交给 ClipStore；每分钟按保留时长清一次。
///
/// 系统没有剪切板变化的通知，只能轮询 `changeCount`，0.5 秒一次（Maccy、Clipy、Tinycast 也都是这个间隔）。
/// 读剪切板、看前台应用在主线程；认类型、算哈希、转 PNG、写库都在 ClipStore 这个 actor 里，不卡主线程。
@MainActor
final class Recorder {
    private let store: ClipStore
    private let settings: Settings
    private let pasteboard: NSPasteboard
    private var lastChangeCount = 0
    private var timers: [Timer] = []

    init(store: ClipStore, settings: Settings, pasteboard: NSPasteboard) {
        self.store = store
        self.settings = settings
        self.pasteboard = pasteboard
    }

    func start() {
        // 启动时已经在剪切板上的不记：不然每次重启都会把它当成刚复制的，挪到最前。
        lastChangeCount = pasteboard.changeCount
        timers = [
            schedule(every: 0.5, tolerance: 0.1) { [weak self] in self?.poll() },
            // 保留时长最短 1 小时，每分钟清一次，过期的最多多留一分钟。是一条走索引的 DELETE，很便宜。
            schedule(every: 60, tolerance: 10) { [weak self] in self?.purge() },
        ]
        purge()
    }

    /// Mochi 自己刚往剪切板上写了东西（粘贴、复制历史里的一条），这次变化不记，不然来源会记成当前的前台应用。
    func ignoreCurrentChange() {
        lastChangeCount = pasteboard.changeCount
    }

    private func schedule(every interval: TimeInterval, tolerance: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated(action) }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard !settings.isPaused else { return }
        let app = NSWorkspace.shared.frontmostApplication
        if let id = app?.bundleIdentifier, settings.ignoredApps.contains(id) {
            log.debug("skip: ignored app \(id, privacy: .public)")
            return
        }
        let snapshot = read(sourceBundleID: app?.bundleIdentifier, sourceName: app?.localizedName)
        Task { [store] in
            do {
                let result = try await store.record(snapshot)
                log.debug("record: \(String(describing: result), privacy: .public)")
            } catch {
                log.error("record failed: \(error, privacy: .public)")
            }
        }
    }

    /// 读下剪切板。带密码标记的只记类型名、不读数据，密码不进内存。
    private func read(sourceBundleID: String?, sourceName: String?) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems ?? []
        let types = items.map { $0.types.map(\.rawValue) }
        let marked = types.joined().contains(where: PasteboardTypes.skipMarkers.contains)
        let snapshotItems = zip(items, types).map { item, types in
            var data: [String: Data] = [:]
            if !marked {
                for type in PasteboardTypes.captured where types.contains(type) {
                    data[type] = item.data(forType: NSPasteboard.PasteboardType(type))
                }
            }
            return PasteboardSnapshot.Item(types: types, data: data)
        }
        return PasteboardSnapshot(items: snapshotItems, sourceBundleID: sourceBundleID, sourceName: sourceName)
    }

    /// 按现在的保留时长清掉过期的。设置里改了保留时长也调它。
    func purge() {
        guard let cutoff = settings.retention.cutoff() else { return }
        Task { [store] in
            do {
                let removed = try await store.purge(before: cutoff)
                if removed > 0 { log.notice("purged \(removed) clips") }
            } catch {
                log.error("purge failed: \(error, privacy: .public)")
            }
        }
    }
}
