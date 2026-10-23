// EventLog.swift — 本地诊断日志
//
// 系统统一日志（log show）在受限环境里读不到，黑屏这类问题又没法当场观察，
// 所以关键事件额外写一份到本地文件：~/Library/Logs/MacOSDisplayToggle/events.log
// 超过 512 KB 自动轮换为 events.old.log，最多占用约 1 MB。

import Foundation
import CoreGraphics

enum EventLog {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacOSDisplayToggle", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("events.log") }

    private static let maxBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "MacOSDisplayToggle.EventLog")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        NSLog("MacOSDisplayToggle: %@", message)
        queue.async { append(line) }
    }

    /// 当前在线显示器的一行摘要，例如「1内 3外」，空列表显示「无」
    static func displaySummary() -> String {
        let ids = Screens.ids().sorted()
        guard !ids.isEmpty else { return "无" }
        return ids.map { "\($0)\(CGDisplayIsBuiltin($0) != 0 ? "内" : "外")" }.joined(separator: " ")
    }

    private static func append(_ line: String) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
               size > maxBytes {
                let old = directory.appendingPathComponent("events.old.log")
                try? fileManager.removeItem(at: old)
                try? fileManager.moveItem(at: fileURL, to: old)
            }
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // 日志写失败不能影响主流程
        }
    }
}
