// Version.swift — 版本号的唯一来源
//
// 每次发版只改这里的 number；build.sh 会读取它写进 Info.plist，
// 并把构建时间作为 build 号，方便区分同一版本的多次构建。
// 变更内容记录在 README.md 的「版本说明」一节。

import Foundation

enum AppVersion {
    static let number = "0.9.0"

    /// 构建号（构建时间 yyyyMMddHHmm），直接编译的测试程序里没有 Info.plist，显示 dev
    ///
    /// 通过 /usr/local/bin/macosdisplaytoggle 软链调用时，Bundle.main 不会顺着软链找到 app，
    /// 所以先解析出真实的可执行文件路径，再往上三级定位到 .app 读 Info.plist。
    static var build: String {
        if let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { return value }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev" }
        let appURL = executable.deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()                      // Contents
            .deletingLastPathComponent()                      // MacOSDisplayToggle.app
        return Bundle(url: appURL)?.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }

    /// 面板里显示的短版本，例如 v0.8.0
    static var short: String { "v\(number)" }

    /// 命令行与日志里显示的完整版本，例如 v0.8.0 (build 202610231620)
    static var full: String { "v\(number) (build \(build))" }
}
