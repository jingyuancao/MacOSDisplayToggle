// 只读显示探针：排查「关内屏 + 拔线」这类黑屏问题时，把各路信号同时打出来。
//
// 2026-10-23 用它确认了根因：拔线后 online / active 都会剩下一个新 ID 的幽灵屏，
// NSScreen 也会陈旧十几秒，唯一可靠的是 DCPAVServiceProxy（服务数归零）。
// 以后改兜底逻辑时可以再用它对照真实信号。
//
// 用法：./scripts/probe-displays.sh
// 复现步骤：面板里关掉内屏 → 拔掉外接屏线缆 → 观察输出 10–20 秒 → Ctrl-C。
//
// 所有行带 [probe] 前缀，便于和其它日志区分。

import Foundation
import AppKit
import CoreGraphics

func label(_ id: CGDirectDisplayID) -> String {
    let kind = CGDisplayIsBuiltin(id) != 0 ? "内" : "外"
    return "\(id)\(kind)"
}

func setText(_ ids: Set<CGDirectDisplayID>) -> String {
    ids.isEmpty ? "无" : ids.sorted().map(label).joined(separator: " ")
}

print("[probe] 探针启动；Ctrl-C 结束")
fflush(stdout)

let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let online = Screens.ids()
    let active = Screens.activeIDs()
    let windowServer = Screens.windowServerIDs()
    let link = Screens.externalLink()
    let disabled = StateStore.load().disabled
    let disabledText = disabled.isEmpty
        ? "无"
        : disabled.map { "\($0.id)\($0.isBuiltin == true ? "内" : "外")" }.joined(separator: " ")

    // 每块屏的活跃/睡眠标志，帮助判断幽灵屏到底是什么状态
    let detail = online.union(active).sorted().map { id -> String in
        "\(label(id))[active=\(CGDisplayIsActive(id) != 0 ? 1 : 0) asleep=\(CGDisplayIsAsleep(id) != 0 ? 1 : 0)]"
    }.joined(separator: " ")

    print("[probe] online=\(setText(online)) active=\(setText(active)) "
          + "ws=\(setText(windowServer)) externalLink=\(link.map { $0 ? "true" : "false" } ?? "nil") "
          + "disabled=\(disabledText) | \(detail)")
    fflush(stdout)
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
