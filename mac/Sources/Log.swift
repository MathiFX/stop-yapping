import Darwin
import Foundation

/// Appends to ~/Library/Logs/Stop Yapping/StopYapping.log and records crashes there too.
enum Log {
    static let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Stop Yapping")
    static let file = folder.appendingPathComponent("StopYapping.log")
    private static let maximumSize: UInt64 = 1_000_000
    private static let queue = DispatchQueue(label: "StopYapping.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    /// Kept open so the crash handler can write without allocating.
    fileprivate static var descriptor: Int32 = -1

    static func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep one previous log when the current one grows too large.
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64,
           size > maximumSize {
            let previous = folder.appendingPathComponent("StopYapping.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: file, to: previous)
        }
        descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        installCrashHandlers()
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) [\(getpid())] \(message)\n"
        queue.sync {
            guard descriptor >= 0 else { return }
            line.utf8CString.withUnsafeBufferPointer { buffer in
                _ = Darwin.write(descriptor, buffer.baseAddress, buffer.count - 1)
            }
        }
    }

    // MARK: Crash capture

    private static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            Log.write("CRASH uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n"))
        }
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(signalNumber, crashSignalHandler)
        }
        // A polite stop (logout, shutdown, `kill`) is not a crash: note it and exit cleanly.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, stopSignalHandler)
        }
    }
}

/// Only async-signal-safe calls in here: no allocation, no locks.
private func writeRaw(_ fd: Int32, _ text: StaticString) {
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

private func writeNumber(_ fd: Int32, _ value: Int32) {
    var digits: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    var n = max(0, min(9999, Int(value)))
    var count = 0
    withUnsafeMutableBytes(of: &digits) { bytes in
        repeat { bytes[3 - count] = UInt8(48 + n % 10); n /= 10; count += 1 } while n > 0 && count < 4
        _ = write(fd, bytes.baseAddress! + (4 - count), count)
    }
}

private func crashSignalHandler(_ signalNumber: Int32) {
    let fd = Log.descriptor
    if fd >= 0 {
        writeRaw(fd, "CRASH signal ")
        writeNumber(fd, signalNumber)
        writeRaw(fd, ", backtrace:\n")
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
            let count = backtrace(frames.baseAddress, 64)
            backtrace_symbols_fd(frames.baseAddress, count, fd)
        }
    }
    // Let the system finish the crash (and write its own report).
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

private func stopSignalHandler(_ signalNumber: Int32) {
    let fd = Log.descriptor
    if fd >= 0 {
        writeRaw(fd, "Stopped by signal ")
        writeNumber(fd, signalNumber)
        writeRaw(fd, "\n")
    }
    _exit(0)
}
