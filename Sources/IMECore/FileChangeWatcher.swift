import Foundation

/// 监视一个文件的变化（含 Excel/Numbers 那种“写临时文件再改名”的保存方式）：
/// 同时监视所在目录和文件本身；变化后防抖，再按 修改时间+大小+inode 判断是否真的变了。
public final class FileChangeWatcher: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var fingerprint: String?

    public init(url: URL, debounce: TimeInterval = 0.3, queue: DispatchQueue = DispatchQueue(label: "TranslateIME.glossary.watch"),
                onChange: @escaping @Sendable () -> Void) {
        self.url = url; self.debounce = debounce; self.queue = queue; self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            fingerprint = Self.fingerprint(url)
            armDirectory()
            armFile()
        }
    }

    public func stop() {
        dirSource?.cancel(); dirSource = nil
        fileSource?.cancel(); fileSource = nil
        pending?.cancel(); pending = nil
    }

    static func fingerprint(_ url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(m)|\(a[.size] ?? 0)|\(a[.systemFileNumber] ?? 0)"
    }

    private func armDirectory() {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        dirSource = s
    }

    private func armFile() {
        fileSource?.cancel(); fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write, .extend, .rename, .delete, .attrib], queue: queue)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        fileSource = s
    }

    private func changed() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.armFile()                      // 改名保存后文件是新的 inode：重新挂上
            let fp = Self.fingerprint(self.url)
            guard fp != self.fingerprint else { return }
            self.fingerprint = fp
            self.onChange()
        }
        pending = w
        queue.asyncAfter(deadline: .now() + debounce, execute: w)
    }
}
