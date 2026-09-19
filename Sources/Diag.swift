import Darwin
import Foundation

/// 运行轨迹 + 崩溃捕获（自签真机排障用，不依赖 Xcode / Mac）。
///
/// 产物（App 沙盒 Documents 下，App 内「诊断」页可查看 / 复制 / 分享 / 清空）：
/// - `trace.log`：本次运行关键阶段的滚动日志
/// - `crash-last.txt`：本次运行若崩溃，写入信号 + 栈回溯 + 崩溃前日志
/// - `crash-prev.txt`：上一次运行留下的崩溃报告（每次启动时归档，供崩溃后排查）
enum Diag {

    // MARK: - 路径

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var traceURL: URL { documentsURL.appendingPathComponent("trace.log") }
    static var crashURL: URL { documentsURL.appendingPathComponent("crash-last.txt") }
    static var previousCrashURL: URL { documentsURL.appendingPathComponent("crash-prev.txt") }

    // MARK: - 状态（信号处理用到的全部预先分配）

    private static let ioQueue = DispatchQueue(label: "ttyb.diag.io")
    private static let stampLock = NSLock()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static var traceFD: Int32 = -1
    private static let traceLimitBytes = 256 * 1024

    private static let frameCount = 128
    private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
    private static let traceTailSize = 16384
    private static let traceTail = UnsafeMutablePointer<UInt8>.allocate(capacity: 16384)

    private typealias BacktraceFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32) -> Int32
    private typealias BacktraceSymbolsFDFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32, Int32) -> Void

    private static var backtraceFn: BacktraceFn?
    private static var backtraceSymbolsFDFn: BacktraceSymbolsFDFn?

    // MARK: - 安装

    /// 在 App 启动最早时机调用（TTYBApp.init）
    static func install() {
        archivePreviousCrash()
        openTrace()
        resolveSymbols()
        installHandlers()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("========== 启动 v\(version) build \(build) ==========")
        if hasPreviousCrash() {
            log("提示：上一次运行发生过崩溃，可在「诊断」页查看 crash-prev.txt")
        }
    }

    private static func resolveSymbols() {
        // 动态解析 backtrace，避免不同 SDK 下的链接差异
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "backtrace") {
            backtraceFn = unsafeBitCast(sym, to: BacktraceFn.self)
        }
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "backtrace_symbols_fd") {
            backtraceSymbolsFDFn = unsafeBitCast(sym, to: BacktraceSymbolsFDFn.self)
        }
    }

    private static func archivePreviousCrash() {
        let fm = FileManager.default
        let old = (try? String(contentsOf: crashURL, encoding: .utf8)) ?? ""
        guard !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? fm.removeItem(at: crashURL)
            return
        }
        try? fm.removeItem(at: previousCrashURL)
        try? fm.moveItem(at: crashURL, to: previousCrashURL)
    }

    private static func openTrace() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: traceURL.path),
           let size = attrs[.size] as? Int, size > traceLimitBytes {
            try? fm.removeItem(at: traceURL)
        }
        if !fm.fileExists(atPath: traceURL.path) {
            fm.createFile(atPath: traceURL.path, contents: nil)
        }
        traceFD = open(traceURL.path, O_WRONLY | O_APPEND)
    }

    private static func installHandlers() {
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, diagSignalHandler)
        }
        NSSetUncaughtExceptionHandler { exception in
            Diag.writeUncaughtException(exception)
        }
    }

    // MARK: - 日志

    /// 关键阶段日志（异步落盘，调用方不阻塞）
    static func log(_ text: String) {
        let line = "[\(stamp())] \(text)\n"
        let fd = traceFD
        ioQueue.async {
            guard fd >= 0, let data = line.data(using: .utf8) else { return }
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress { _ = write(fd, base, raw.count) }
            }
        }
    }

    private static func stamp() -> String {
        stampLock.lock()
        defer { stampLock.unlock() }
        return stampFormatter.string(from: Date())
    }

    // MARK: - 读取 / 清理

    static func traceText(maxLines: Int = 500) -> String {
        guard let text = try? String(contentsOf: traceURL, encoding: .utf8), !text.isEmpty else {
            return "（暂无运行日志）"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLines { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func previousCrashText() -> String? {
        guard let text = try? String(contentsOf: previousCrashURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func hasPreviousCrash() -> Bool { previousCrashText() != nil }

    static func clearAll() {
        let fm = FileManager.default
        try? fm.removeItem(at: previousCrashURL)
        try? fm.removeItem(at: crashURL)
        try? fm.removeItem(at: traceURL)
        traceFD = -1
        openTrace()
        log("日志已清空")
    }

    // MARK: - 崩溃写入

    fileprivate static func writeUncaughtException(_ exception: NSException) {
        let report = """
        ===== 未捕获异常 (NSException) =====
        \(stamp())
        \(exception.name.rawValue): \(exception.reason ?? "")
        \(exception.callStackSymbols.joined(separator: "\n"))

        ----- 崩溃前运行日志 -----
        \(traceText())
        """
        appendCrash(report)
    }

    /// 信号处理上下文中调用：只使用 open / write / read / lseek / close / fsync
    fileprivate static func handleSignal(_ sig: Int32) {
        let fd = open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            emit(fd, "\n===== 崩溃捕获 =====\n")
            emit(fd, "信号: \(signalName(sig)) (\(sig))\n")

            if let backtraceFn, let backtraceSymbolsFDFn {
                let count = backtraceFn(frames, Int32(frameCount))
                if count > 0 {
                    emit(fd, "----- 调用栈 -----\n")
                    backtraceSymbolsFDFn(frames, count, fd)
                }
            }

            dumpTraceTail(fd)
            fsync(fd)
            close(fd)
        }

        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func dumpTraceTail(_ fd: Int32) {
        let src = open(traceURL.path, O_RDONLY)
        guard src >= 0 else { return }
        let size = lseek(src, 0, SEEK_END)
        guard size > 0 else { close(src); return }
        let want = size > Int64(traceTailSize) ? traceTailSize : Int(size)
        _ = lseek(src, size - Int64(want), SEEK_SET)
        let got = read(src, traceTail, want)
        close(src)
        guard got > 0 else { return }
        emit(fd, "\n----- 崩溃前运行日志（尾部）-----\n")
        _ = write(fd, traceTail, got)
        emit(fd, "\n")
    }

    private static func appendCrash(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let fd = open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = write(fd, base, raw.count) }
        }
        fsync(fd)
        close(fd)
        log("崩溃报告已写入 crash-last.txt")
    }

    private static func emit(_ fd: Int32, _ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = write(fd, base, raw.count) }
        }
    }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT(abort/断言失败)"
        case SIGSEGV: return "SIGSEGV(内存访问越界)"
        case SIGBUS: return "SIGBUS(总线错误)"
        case SIGILL: return "SIGILL(非法指令/Swift 强制解包失败)"
        case SIGTRAP: return "SIGTRAP(陷阱/Swift 断言)"
        case SIGFPE: return "SIGFPE(算术异常)"
        default: return "SIG\(sig)"
        }
    }
}

/// 顶层 C 函数，供 signal() 注册（不能捕获上下文，故必须放在文件作用域）
private func diagSignalHandler(_ sig: Int32) {
    Diag.handleSignal(sig)
}
