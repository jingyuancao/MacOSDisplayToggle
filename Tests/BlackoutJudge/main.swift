// 黑屏判定回归测试。
//
// 用例来自 2026-10-23 的一次真实复现（探针记录的信号）：
//   关掉内屏后拔线，19.5 秒里 online / active 都剩一个幽灵外接屏（15），
//   NSScreen 停在陈旧列表，DCPAVServiceProxy 服务数归零。
//   旧实现把「零服务」当成 nil（无法判断），于是黑屏兜底永远不触发。
// 这个测试必须先于修复变红（退出码非 0），修复后转绿。

import Foundation
import CoreGraphics

var failures = 0

func check(_ name: String, _ passes: Bool) {
    if passes {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)")
    }
}

print("外接链路信号")

// 1. 查询成功但一个服务都没有 —— 拔线后的真实状态，必须判定为「没有外接链路」
//    旧实现返回 nil，正是黑屏兜底失效的根因。
let noServices = Screens.externalLink(querySucceeded: true, locations: [])
print("  · 零服务 → \(noServices.map { $0 ? "true" : "false" } ?? "nil")")
check("查询成功但零服务时判定为无外接链路（false）", noServices == false)

// 2. 只有内屏的代理 —— 同样没有外接链路
check("只有 Internal 服务时判定为无外接链路",
      Screens.externalLink(querySucceeded: true, locations: ["Internal"]) == false)

// 3. 有 External 服务 —— 有外接链路
check("存在 External 服务时判定为有外接链路",
      Screens.externalLink(querySucceeded: true, locations: ["Internal", "External"]) == true)

// 4. IOKit 查询本身失败 —— 唯一该返回 nil 的情况
check("IOKit 查询失败时返回 nil",
      Screens.externalLink(querySucceeded: false, locations: []) == nil)

print("黑屏判定")

// 5. 真实拔线场景：幽灵外接屏 15 + 外接屏 3 已移除 + 无外接链路
let ghostAfterUnplug = BlackoutSignals(
    online: [15],
    builtinOnline: [],
    disabledBuiltin: true,
    removed: [3],
    externalLink: false)
let ghostReason = BlackoutJudge.reason(ghostAfterUnplug)
print("  · 幽灵场景判定：\(ghostReason ?? "nil（认为还有画面）")")
check("拔线后仅剩幽灵外接屏时必须判定黑屏", ghostReason != nil)

// 6. 内屏在线 —— 一定有画面
check("内屏在线时不判定黑屏",
      BlackoutJudge.reason(BlackoutSignals(online: [1], builtinOnline: [1],
                                           disabledBuiltin: false, removed: [],
                                           externalLink: nil)) == nil)

// 7. 双屏在线 —— 正常
check("内屏与外接屏都在线时不判定黑屏",
      BlackoutJudge.reason(BlackoutSignals(online: [1, 3], builtinOnline: [1],
                                           disabledBuiltin: false, removed: [],
                                           externalLink: true)) == nil)

// 8. 在线列表为空 —— 黑屏
check("在线列表为空时判定黑屏",
      BlackoutJudge.reason(BlackoutSignals(online: [], builtinOnline: [],
                                           disabledBuiltin: true, removed: [],
                                           externalLink: nil)) != nil)

// 9. 外接屏全部收到过移除通知 —— 列表残留
check("外接屏全部已被移除时判定黑屏",
      BlackoutJudge.reason(BlackoutSignals(online: [3], builtinOnline: [],
                                           disabledBuiltin: true, removed: [3],
                                           externalLink: true)) != nil)

// 10. 外接屏真实在线、链路正常 —— 不误报
check("外接屏真实可用时不误报黑屏",
      BlackoutJudge.reason(BlackoutSignals(online: [3], builtinOnline: [],
                                           disabledBuiltin: true, removed: [],
                                           externalLink: true)) == nil)

// 11. 合盖（内屏不在线但不是我们关的）—— 交给系统，不介入
check("合盖导致内屏离线时不介入",
      BlackoutJudge.reason(BlackoutSignals(online: [3], builtinOnline: [],
                                           disabledBuiltin: false, removed: [],
                                           externalLink: true)) == nil)

print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
