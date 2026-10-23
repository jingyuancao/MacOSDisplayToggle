// BlackoutJudge.swift — 「现在是不是看不到任何画面」的纯判断
//
// 输入全部由调用方注入，不直接读系统，这样拔线这种没法自动化的场景
// 可以拿真实日志里的信号做回归测试。DisplayStore 负责把系统状态翻译成 Signals。

import Foundation
import CoreGraphics

/// 判定黑屏所需的全部信号。
struct BlackoutSignals {
    /// CGGetOnlineDisplayList：系统「自认为」在线的屏（拔线后可能残留幽灵）
    let online: Set<CGDirectDisplayID>
    /// online 中属于内屏的那些
    let builtinOnline: Set<CGDirectDisplayID>
    /// 内屏是否是被本工具主动关掉的（合盖不算，那是系统行为）
    let disabledBuiltin: Bool
    /// 收到过系统「移除」通知、但可能还残留在 online 里的显示器
    let removed: Set<CGDirectDisplayID>
    /// 视频链路上是否挂着外接屏；nil 表示无法判断
    let externalLink: Bool?
}

enum BlackoutJudge {
    /// 返回黑屏原因；正常时返回 nil。
    ///
    /// 只看「在线列表为空」不够：拔线后 WindowServer 可能把外接屏在列表里残留一阵，
    /// 列表不空但实际没有画面。所以内屏不在线时，还要确认外接屏是真的可用：
    /// 收到过系统的「移除」通知、或 IOKit 显示视频链路已断开，都说明列表里的外接屏只是残留。
    static func reason(_ signals: BlackoutSignals) -> String? {
        if signals.online.isEmpty { return "在线显示器列表为空" }

        // 内屏在线，画面至少在内屏上
        if !signals.builtinOnline.isEmpty { return nil }

        // 内屏不在线（被我们关了，或合盖）。只有被我们关掉时才需要介入，合盖由系统自己处理
        guard signals.disabledBuiltin else { return nil }

        let externals = signals.online.subtracting(signals.builtinOnline)
        let stale = externals.intersection(signals.removed)
        if !externals.isEmpty, stale.count == externals.count {
            return "内屏已关闭，外接屏 \(stale.sorted()) 已被系统移除（列表残留）"
        }
        if signals.externalLink == false {
            return "内屏已关闭，外接视频链路已断开（列表中的 \(externals.sorted()) 是残留）"
        }
        return nil
    }
}
