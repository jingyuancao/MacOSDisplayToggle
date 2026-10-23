// DisplayStore.swift — 显示器状态与业务规则
//
// 负责：维护「哪些屏被主动下线」的记录、把系统状态翻译成视图数据、执行开关与分辨率操作。
// 所有对系统的调用都经由 DisplayAPI，这里只做编排和状态一致性保障。

import Foundation
import CoreGraphics

// MARK: - 视图数据

struct DisplayItem: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let isBuiltin: Bool
    let isEnabled: Bool
}

struct ResolutionOption: Identifiable {
    let id: String
    let width: Int          // 逻辑分辨率
    let height: Int
    let pixelWidth: Int     // 实际渲染像素
    let pixelHeight: Int
    let scalePercent: Int   // 缩放比例：100% = 不放大，200% = Retina 标准
    let isNoNotch: Bool     // 宽高比大于面板，上下留黑边，刘海落在黑边里
    let isHiDPI: Bool       // 只有「当前档被强制补进列表」时才可能是 false
    let isCurrent: Bool
    let mode: CGDisplayMode

    var label: String { "\(width) × \(height)" }
    var displayName: String {
        var name = label
        if isNoNotch { name += "  无刘海" }
        if !isHiDPI { name += "  非 Retina" }
        return name
    }
}

// MARK: - 错误

enum DisplayError: LocalizedError {
    case apiUnavailable
    case displayNotFound
    case wouldDisableAll
    case cannotDisable(String)
    case cannotRestore
    case resolutionNotApplied
    case system(CGError)

    var errorDescription: String? {
        switch self {
        case .apiUnavailable:
            return "当前系统不提供显示启停接口"
        case .displayNotFound:
            return "找不到该显示器"
        case .wouldDisableAll:
            return "至少要保留一块屏幕在显示"
        case .cannotDisable(let names):
            return "\(names) 未能关闭"
        case .cannotRestore:
            return "恢复失败，请拔插 Type-C 线缆后重试"
        case .resolutionNotApplied:
            return "分辨率切换未生效"
        case .system(let error):
            return "系统调用失败（CGError \(error.rawValue)）"
        }
    }
}

// MARK: - 持久化

/// 被主动下线的显示器。记下 id 用于恢复（同一登录会话内 id 稳定），
/// 记下名字和类型，因为下线后 NSScreen 就查不到它了，列表里还得正确显示。
struct DisabledRecord: Codable {
    var id: UInt32
    var name: String
    /// 可选是为了兼容早期没有这个字段的状态文件
    var isBuiltin: Bool?
}

struct PersistedState: Codable {
    var disabled: [DisabledRecord] = []
}

enum StateStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacOSDisplayToggle", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// v0.9.0 之前项目叫 OnlyInternal，状态存在旧目录。下线记录关系到「能不能把屏恢复回来」，
    /// 所以首次运行时若新文件不存在，就把旧文件复制过来（旧文件保留不删）。
    private static var legacyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OnlyInternal", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    static func load() -> PersistedState {
        migrateLegacyIfNeeded()
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return PersistedState()
        }
        return state
    }

    private static func migrateLegacyIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: fileURL.path),
              fileManager.fileExists(atPath: legacyFileURL.path) else { return }
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        try? fileManager.copyItem(at: legacyFileURL, to: fileURL)
    }

    static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MacOSDisplayToggle: 状态写入失败 \(error.localizedDescription)")
        }
    }
}

// MARK: - 业务状态

final class DisplayStore {
    static let shared = DisplayStore()

    private var state: PersistedState

    /// 显示器名字缓存。显示器刚上线那一刻 NSScreen 还没刷新，
    /// 用它兜住，避免列表里闪出「显示器 3」这种占位名。
    private var nameCache: [UInt32: String] = [:]

    private enum Timing {
        static let afterConfiguration: useconds_t = 180_000
        static let beforeRetry: useconds_t = 400_000
        static let afterScanProbe: useconds_t = 200_000
    }

    private init() {
        state = StateStore.load()
        loadedModificationDate = (try? FileManager.default.attributesOfItem(atPath: StateStore.fileURL.path))?[.modificationDate] as? Date
        for record in state.disabled { nameCache[record.id] = record.name }
        reconcileWithReality()
    }

    // MARK: 查询

    /// 完整列表：当前在线的，加上已下线但仍有记录的
    func snapshot() -> [DisplayItem] {
        reloadIfChangedOnDisk()

        let online = Screens.online()
        let onlineIDs = Set(online.map(\.id))
        var items: [DisplayItem] = []

        for screen in online {
            let name: String
            if let reported = screen.name {
                nameCache[screen.id] = reported
                name = reported
            } else {
                name = nameCache[screen.id] ?? "显示器 \(screen.id)"
            }
            items.append(DisplayItem(id: screen.id, name: name,
                                     isBuiltin: screen.isBuiltin, isEnabled: true))
        }

        for record in state.disabled where !onlineIDs.contains(record.id) {
            items.append(DisplayItem(id: record.id, name: record.name,
                                     isBuiltin: record.isBuiltin ?? false, isEnabled: false))
        }

        return items.sorted { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
            return lhs.id < rhs.id
        }
    }

    var hasExternalEnabled: Bool {
        snapshot().contains { !$0.isBuiltin && $0.isEnabled }
    }

    // MARK: 开关

    /// 批量设置显示器的启用状态。单台就传一个元素的数组。
    ///
    /// 关闭时遵循「先开再关」：如果关掉这批屏之后一块都不剩，会先把备用的屏点亮并确认
    /// 已经真正上线，才去关目标屏。任何时刻都不会出现全黑、无从操作的中间状态。
    @discardableResult
    func setEnabled(_ ids: [UInt32], _ enabled: Bool) -> Result<Void, DisplayError> {
        guard SkyLight.isAvailable else { return .failure(.apiUnavailable) }
        guard !ids.isEmpty else { return .success(()) }

        let items = snapshot()
        let known = Set(items.map(\.id))
        guard ids.allSatisfy({ known.contains($0) }) else { return .failure(.displayNotFound) }

        EventLog.write("\(enabled ? "启用" : "关闭") \(ids)；操作前在线 \(EventLog.displaySummary())")
        defer { EventLog.write("操作后在线 \(EventLog.displaySummary())") }

        if enabled {
            return applyEnable(ids, items: items)
        }

        // 关闭前先确认还有别的屏在撑着
        let survivors = items.filter { $0.isEnabled && !ids.contains($0.id) }
        if survivors.isEmpty {
            let spares = items.filter { !$0.isEnabled && !ids.contains($0.id) }
            guard !spares.isEmpty else { return .failure(.wouldDisableAll) }

            // 备份屏必须真的点亮才算数，失败就放弃关闭，绝不冒险
            var rescued = false
            for spare in spares {
                if case .success = applyEnable([spare.id], items: items) {
                    rescued = true
                    break
                }
            }
            guard rescued,
                  snapshot().contains(where: { $0.isEnabled && !ids.contains($0.id) }) else {
                return .failure(.wouldDisableAll)
            }
            // 让系统先把新拓扑消化完，再关目标屏
            usleep(Timing.beforeRetry)
        }

        return applyDisable(ids, items: items)
    }

    private func applyEnable(_ ids: [UInt32], items: [DisplayItem]) -> Result<Void, DisplayError> {
        let error = SkyLight.apply(ids.map { (display: CGDirectDisplayID($0), enabled: true) })
        settle()

        // 显示器可能掉进「链路在、系统没重新枚举」的状态，逐级升级手段
        var online = Screens.ids()
        if !ids.allSatisfy({ online.contains($0) }) {
            SkyLight.redetect()
            settle()
            online = Screens.ids()
        }
        if !ids.allSatisfy({ online.contains($0) }) {
            scanEnable()
            online = Screens.ids()
        }

        guard ids.allSatisfy({ online.contains($0) }) else {
            return .failure(error == .success ? .cannotRestore : .system(error))
        }

        let enabled = Set(ids)
        state.disabled.removeAll { enabled.contains($0.id) }
        // 刚由我们亲手启用的屏是确定可用的，清掉可能残留的「已移除」标记
        ids.forEach { removedDisplays.remove(CGDirectDisplayID($0)) }
        persist()
        return .success(())
    }

    private func applyDisable(_ ids: [UInt32], items: [DisplayItem]) -> Result<Void, DisplayError> {
        var lastError: CGError = .success
        var stillOn: [UInt32] = ids
        var online: Set<CGDirectDisplayID> = []

        // 刚点亮备份屏就立刻关主屏，系统可能还没提交完拓扑变更而拒绝，
        // 所以这里重试几轮。备份屏已经亮着，即使重试也不存在全黑风险。
        for attempt in 0..<3 {
            if attempt > 0 { usleep(Timing.beforeRetry) }
            lastError = SkyLight.apply(ids.map { (display: CGDirectDisplayID($0), enabled: false) })
            settle()
            online = Screens.ids()
            stillOn = ids.filter { online.contains($0) }
            if stillOn.isEmpty { break }
        }

        guard stillOn.isEmpty else {
            let list = stillOn.map { name(of: $0, in: items) }.joined(separator: "、")
            return .failure(lastError == .success ? .cannotDisable(list) : .system(lastError))
        }

        // 底线检查：万一系统真的一块屏都不剩，立刻把它们开回来，绝不把用户留在全黑里
        if online.isEmpty {
            EventLog.write("关闭后已无可用显示器，立即回滚")
            _ = SkyLight.apply(ids.map { (display: CGDirectDisplayID($0), enabled: true) })
            settle()
            return .failure(.wouldDisableAll)
        }

        for id in ids where !state.disabled.contains(where: { $0.id == id }) {
            let item = items.first { $0.id == id }
            state.disabled.append(DisabledRecord(id: id,
                                                 name: name(of: id, in: items),
                                                 isBuiltin: item?.isBuiltin ?? false))
        }
        persist()
        return .success(())
    }

    /// 关闭全部外接屏。走单次配置事务，多屏时不会逐台等待。
    @discardableResult
    func disableAllExternals() -> Result<Void, DisplayError> {
        let targets = snapshot().filter { $0.isEnabled && !$0.isBuiltin }.map(\.id)
        guard !targets.isEmpty else { return .success(()) }   // 已经是仅内屏，幂等
        return setEnabled(targets, false)
    }

    /// 恢复所有被下线的显示器。
    /// 显示器从待机回来时第一次 enable 偶尔不生效，所以重试三轮并逐级升级手段。
    @discardableResult
    func restoreAll() -> Result<Void, DisplayError> {
        guard SkyLight.isAvailable else { return .failure(.apiUnavailable) }
        EventLog.write("恢复全部；在线 \(EventLog.displaySummary())；下线记录 \(state.disabled.map(\.id))")
        defer { EventLog.write("恢复全部结束；在线 \(EventLog.displaySummary())") }

        let ids = state.disabled.map(\.id)

        // 既没有下线记录、在线列表里也没有外接屏，但视频链路上确实挂着屏：
        // 说明系统把它丢在了「链路在、未枚举」的状态。必须先强制重新检测让系统
        // 重新登记这块屏，再逐个 id 启用才有效——直接 enable 会返回成功但毫无作用。
        if ids.isEmpty {
            let externalOnline = Screens.online().contains { !$0.isBuiltin }
            // 链路状态无法判断（nil）时不贸然扫描，避免每次 all 都白等几秒再误报失败
            guard !externalOnline, Screens.externalLink() == true else { return .success(()) }
            SkyLight.redetect()
            settle()
            scanEnable()
            guard Screens.online().contains(where: { !$0.isBuiltin }) else {
                return .failure(.cannotRestore)
            }
            return .success(())
        }

        var lastError: CGError = .success
        var online: Set<CGDirectDisplayID> = []

        for attempt in 0..<3 {
            if attempt > 0 { usleep(Timing.beforeRetry) }
            lastError = SkyLight.apply(ids.map { (display: CGDirectDisplayID($0), enabled: true) })
            settle()
            online = Screens.ids()
            if ids.allSatisfy({ online.contains($0) }) { break }

            if attempt == 0 {
                SkyLight.redetect()
                settle()
                online = Screens.ids()
            } else if attempt == 1, !Screens.online().contains(where: { !$0.isBuiltin }) {
                scanEnable()
                online = Screens.ids()
            }
        }

        let stillOff = ids.filter { !online.contains($0) }
        state.disabled = state.disabled.filter { stillOff.contains($0.id) }
        persist()

        guard stillOff.isEmpty else {
            return .failure(lastError == .success ? .cannotRestore : .system(lastError))
        }
        return .success(())
    }

    // MARK: 分辨率

    @discardableResult
    func setResolution(_ option: ResolutionOption, for id: UInt32) -> Result<Void, DisplayError> {
        let displayID = CGDirectDisplayID(id)
        let error = ModeCatalog.setMode(option.mode, for: displayID)
        guard error == .success else { return .failure(.system(error)) }
        settle()

        guard let current = ModeCatalog.currentMode(for: displayID),
              current.width == option.width,
              current.height == option.height,
              current.pixelWidth == option.pixelWidth else {
            return .failure(.resolutionNotApplied)
        }
        return .success(())
    }

    // MARK: 内部

    /// 判断当前是否处于「看不到任何画面」的状态，返回原因；正常时返回 nil。
    ///
    /// 只看「在线列表为空」不够：拔线后 WindowServer 可能把外接屏在列表里残留一阵，
    /// 列表不空但实际没有画面。所以内屏不在线时，还要确认外接屏是真的可用：
    /// 收到过系统的「移除」通知、或 IOKit 显示视频链路已断开，都说明列表里的外接屏只是残留。
    func blackoutReason() -> String? {
        reloadIfChangedOnDisk()
        let online = Screens.ids()
        if online.isEmpty { return "在线显示器列表为空" }

        // 内屏在线，画面至少在内屏上
        if online.contains(where: { CGDisplayIsBuiltin($0) != 0 }) { return nil }

        // 内屏不在线（被我们关了，或合盖）。只有被我们关掉时才需要介入，合盖由系统自己处理
        guard state.disabled.contains(where: { $0.isBuiltin == true }) else { return nil }

        let externals = online.filter { CGDisplayIsBuiltin($0) == 0 }
        let stale = externals.filter { removedDisplays.contains($0) }
        if !externals.isEmpty, stale.count == externals.count {
            return "内屏已关闭，外接屏 \(stale.sorted()) 已被系统移除（列表残留）"
        }
        if Screens.externalLink() == false {
            return "内屏已关闭，外接视频链路已断开（列表中的 \(externals.sorted()) 是残留）"
        }
        return nil
    }

    /// 系统通知过「已移除」、但可能还残留在在线列表里的显示器。由顶栏 App 的拓扑回调维护。
    private var removedDisplays = Set<CGDirectDisplayID>()

    func noteDisplayRemoved(_ id: CGDirectDisplayID) { removedDisplays.insert(id) }
    func noteDisplayAdded(_ id: CGDirectDisplayID) { removedDisplays.remove(id) }

    /// 有没有真正可见的画面：内屏在线，或者有在线且未被移除的外接屏
    private func hasVisibleOutput() -> Bool {
        let online = Screens.ids()
        if online.contains(where: { CGDisplayIsBuiltin($0) != 0 }) { return true }
        let liveExternals = online.filter { CGDisplayIsBuiltin($0) == 0 && !removedDisplays.contains($0) }
        return !liveExternals.isEmpty && Screens.externalLink() != false
    }

    /// 黑屏救援：优先把内屏开回来（它永远在，不依赖线缆），多轮重试并逐级升级手段。
    /// 每一步都写本地事件日志，方便事后定位是哪一步没起作用。
    ///
    /// - Returns: 救援后是否已有可用画面
    @discardableResult
    func rescueFromBlackout(reason: String) -> Bool {
        EventLog.write("救援开始：\(reason)；在线 \(EventLog.displaySummary())；下线记录 \(state.disabled.map { "\($0.id)\($0.isBuiltin == true ? "内" : "外")" })")
        guard SkyLight.isAvailable else {
            EventLog.write("救援失败：SkyLight 接口不可用")
            return false
        }

        // 内屏排最前；没有内屏记录时就把所有下线记录都试一遍
        let builtinIDs = state.disabled.filter { $0.isBuiltin == true }.map(\.id)
        let targets = builtinIDs.isEmpty ? state.disabled.map(\.id) : builtinIDs

        func recovered() -> Bool { hasVisibleOutput() }

        for round in 1...3 {
            if round > 1 { usleep(Timing.beforeRetry) }

            if !targets.isEmpty {
                let error = SkyLight.apply(targets.map { (display: CGDirectDisplayID($0), enabled: true) })
                settle()
                EventLog.write("救援第 \(round) 轮·启用 \(targets)：CGError \(error.rawValue)；在线 \(EventLog.displaySummary())")
                if recovered() { break }
            }

            SkyLight.redetect()
            settle()
            if !targets.isEmpty {
                let error = SkyLight.apply(targets.map { (display: CGDirectDisplayID($0), enabled: true) })
                settle()
                EventLog.write("救援第 \(round) 轮·重新检测后再启用：CGError \(error.rawValue)；在线 \(EventLog.displaySummary())")
                if recovered() { break }
            }

            scanEnable(stopWhen: { Screens.ids().contains { CGDisplayIsBuiltin($0) != 0 } })
            EventLog.write("救援第 \(round) 轮·扫描启用后：在线 \(EventLog.displaySummary())")
            if recovered() { break }
        }

        let online = Screens.ids()
        state.disabled.removeAll { online.contains($0.id) }
        persist()

        let ok = recovered()
        EventLog.write(ok ? "救援成功：在线 \(EventLog.displaySummary())" : "救援失败：在线 \(EventLog.displaySummary())")
        return ok
    }

    /// 清理过期记录：被记录的显示器如今又在线了，说明下线状态早已失效。
    /// 在线列表为空时不做清理——那通常意味着查询本身没准备好，而不是所有显示器都下线了。
    private func reconcileWithReality() {
        guard !state.disabled.isEmpty else { return }
        let online = Screens.ids()
        guard !online.isEmpty else { return }

        let before = state.disabled.count
        state.disabled.removeAll { online.contains($0.id) }
        if state.disabled.count != before { persist() }
    }

    /// CLI 和顶栏 App 是两个进程，各持一份内存状态。用文件修改时间判断对方是否写过，
    /// 写过就重新加载，避免顶栏 App 拿着过期记录覆盖掉 CLI 刚写入的状态。
    private var loadedModificationDate: Date?

    private func reloadIfChangedOnDisk() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: StateStore.fileURL.path))?[.modificationDate] as? Date
        guard let modified, modified != loadedModificationDate else { return }
        state = StateStore.load()
        for record in state.disabled { nameCache[record.id] = record.name }
        loadedModificationDate = modified
    }

    /// 扫描可能的 display id 逐个启用，用于状态记录丢失后的自愈。
    /// 调用前应先 redetect，否则 enable 会返回成功却不起作用。
    private func scanEnable(stopWhen done: () -> Bool = {
        Screens.online().contains(where: { !$0.isBuiltin })
    }) {
        for probe in CGDirectDisplayID(1)...CGDirectDisplayID(16) {
            if Screens.ids().contains(probe) { continue }
            _ = SkyLight.apply([(display: probe, enabled: true)])
            usleep(Timing.afterScanProbe)
            if done() { return }
        }
    }

    private func name(of id: UInt32, in items: [DisplayItem]) -> String {
        items.first { $0.id == id }?.name ?? "显示器 \(id)"
    }

    private func settle() { usleep(Timing.afterConfiguration) }

    private func persist() {
        StateStore.save(state)
        loadedModificationDate = (try? FileManager.default.attributesOfItem(atPath: StateStore.fileURL.path))?[.modificationDate] as? Date
    }
}
