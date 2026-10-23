// DisplayAPI.swift — 系统显示接口层
//
// 只负责与 CoreGraphics / SkyLight / IOKit 打交道：枚举显示器、改启用状态、改分辨率、枚举模式。
// 不含任何 UI 状态、持久化或业务规则，方便单独验证。

import Foundation
import CoreGraphics
import AppKit
import IOKit

// MARK: - SkyLight 私有接口

/// CGSConfigureDisplayEnabled 的真实签名（经崩溃栈与反汇编级实测确认）为：
///     CGError CGSConfigureDisplayEnabled(CGSConfigDataRef cfg, CGDirectDisplayID display, bool enabled)
///
/// 第一个参数是「显示配置对象」而非 connection id。按 connection id 传会让系统把它当指针解引用，
/// 进程直接段错误——崩溃栈停在 `checkCapacity(CGSConfigData*)`，而那个地址恰好等于传入的 cid。
/// 该配置对象由公开 API `CGBeginDisplayConfiguration` 创建，所以可以借公开事务包住私有调用。
enum SkyLight {
    private typealias ConfigureFn = @convention(c) (UnsafeMutableRawPointer?, CGDirectDisplayID, Int32) -> CGError
    private typealias DetectFn = @convention(c) (Int32) -> CGError
    private typealias ConnectionFn = @convention(c) () -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static let configure: ConfigureFn? = symbol("CGSConfigureDisplayEnabled",
                                                        "SLSConfigureDisplayEnabled")
    private static let detect: DetectFn? = symbol("CGSDetectDisplays", "SLSDetectDisplays")
    private static let connection: ConnectionFn? = symbol("CGSMainConnectionID")

    /// 按候选名依次查找符号（新旧系统里 CGS 与 SLS 两套命名并存）
    private static func symbol<T>(_ names: String...) -> T? {
        guard let handle else { return nil }
        for name in names {
            if let pointer = dlsym(handle, name) {
                return unsafeBitCast(pointer, to: T.self)
            }
        }
        return nil
    }

    static var isAvailable: Bool { configure != nil }

    /// 在同一个配置事务内批量设置显示器的启用状态。
    ///
    /// 返回值只反映 `configure` 调用本身。提交（complete）结果不能作为判据：
    /// 系统在「本次配置无实际变化」或重复提交时常返回 1001，但状态其实已经生效。
    /// 因此调用方必须复查在线列表来确认最终结果。
    static func apply(_ changes: [(display: CGDirectDisplayID, enabled: Bool)]) -> CGError {
        guard let configure else { return .failure }
        var cfg: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&cfg)
        guard begin == .success, let config = cfg else { return begin }

        var firstError: CGError = .success
        for change in changes {
            let err = configure(UnsafeMutableRawPointer(config), change.display, change.enabled ? 1 : 0)
            if err != .success, firstError == .success { firstError = err }
        }
        _ = CGCompleteDisplayConfiguration(config, .forSession)
        return firstError
    }

    /// 强制重新枚举显示器，等价于系统设置里按住 Option 点「检测显示器」
    static func redetect() {
        guard let detect, let connection else { return }
        _ = detect(connection())
    }
}

// MARK: - 显示器枚举

struct ScreenInfo {
    let id: CGDirectDisplayID
    let isBuiltin: Bool
    /// NSScreen 给不出名字时为 nil（显示器刚上线时 WindowServer 可能还没同步）
    let name: String?
}

enum Screens {
    static func ids() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    /// 当前「活跃」的显示器，供诊断探针使用。
    ///
    /// 注意：实测拔线后残留的新 ID 幽灵屏**也会出现在 active 列表里**，
    /// 所以不能单靠它判断「有没有画面」，真正的依据是链路状态（`externalLink`）。
    static func activeIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    /// WindowServer 交给 App 绘制的屏幕集合，供诊断探针使用。
    ///
    /// 注意：实测拔线后 NSScreen 可能陈旧十几秒仍列出已断开的屏，
    /// 因此它不能作为「现在到底有没有画面」的实时依据。
    static func windowServerIDs() -> Set<CGDirectDisplayID> {
        var result = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                result.insert(number.uint32Value)
            }
        }
        return result
    }

    /// 在线显示器及其名字。名字与刘海信息只遍历一次 NSScreen。
    static func online() -> [ScreenInfo] {
        let meta = screenMeta()
        return ids().sorted().map { id in
            ScreenInfo(id: id,
                       isBuiltin: CGDisplayIsBuiltin(id) != 0,
                       name: meta[id]?.name)
        }
    }

    /// NSScreen 能提供的信息：产品名、是否带刘海
    private struct Meta {
        let name: String?
        let hasNotch: Bool
    }

    private static func screenMeta() -> [CGDirectDisplayID: Meta] {
        var result: [CGDirectDisplayID: Meta] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = number.uint32Value
            let name = screen.localizedName
            result[id] = Meta(name: name.isEmpty ? nil : name,
                              hasNotch: screen.safeAreaInsets.top > 0)
        }
        return result
    }

    /// 该屏是否带刘海。只有刘海屏才需要在档位里区分「无刘海」变体。
    ///
    /// NSScreen 的 safeAreaInsets 在显示器刚被重新启用时会滞后，那一瞬间会误报「没刘海」。
    /// 因此只缓存 true（刘海是这块屏的固有属性），false 每次都重新查，避免把瞬时错误固化。
    private static var notchCache: [CGDirectDisplayID: Bool] = [:]

    static func hasNotch(_ id: CGDirectDisplayID) -> Bool {
        if notchCache[id] == true { return true }
        guard let info = screenMeta()[id] else { return false }   // 查不到不下结论
        if info.hasNotch { notchCache[id] = true }
        return info.hasNotch
    }

    /// 视频链路上是否挂着外接屏。即使这块屏已被下线、不在在线列表里，也能识别出来。
    ///
    /// - Returns: `true` 有外接链路；`false` 确定没有；`nil` 无法判断（IOKit 查询失败）。
    ///
    /// 注意「查询成功但一个服务都没有」必须返回 `false`，不能返回 `nil`。
    /// 拔线后 DCPAVServiceProxy 会整体消失，旧实现把它当成「无法判断」，
    /// 导致黑屏兜底在「关内屏 + 拔线」时永远不触发。只有查询本身失败才是 `nil`。
    static func externalLink() -> Bool? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var locations: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString,
                                                              kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                locations.append(location)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return externalLink(querySucceeded: true, locations: locations)
    }

    /// 把 IOKit 查询结果翻译成链路状态，便于用真实拔线场景做回归测试。
    static func externalLink(querySucceeded: Bool, locations: [String]) -> Bool? {
        guard querySucceeded else { return nil }
        return locations.contains("External")
    }
}

// MARK: - 分辨率模式

enum ModeCatalog {
    /// 面板原生像素尺寸。
    ///
    /// 只能取 ioFlags 带 `kDisplayModeNativeFlag` 的模式。若直接对所有模式的像素取最大值，
    /// 会把「超采样」档（4K 屏上的 6720×3780）误当成面板尺寸，后续所有过滤都会失效。
    private static let nativeFlag: UInt32 = 0x0200_0000

    static func allModes(for id: CGDirectDisplayID) -> [CGDisplayMode] {
        // 不传这个键时 HiDPI 模式数为 0，系统只返回硬件原生模式
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }

    static func currentMode(for id: CGDirectDisplayID) -> CGDisplayMode? {
        CGDisplayCopyDisplayMode(id)
    }

    /// 从模式列表反推这块屏是不是刘海屏。
    ///
    /// 刘海屏的特征：同一逻辑宽度下，既有「铺满面板」的档（比例 = 面板比例，含刘海），
    /// 又有「比面板更宽」的档（上下留黑边），例如内屏 1728×1117(1.547) 与 1728×1080(1.600)。
    ///
    /// 不能只看「同宽有多种比例」：外接 4K 屏在宽 640 处就有 1.25/1.33/1.60/1.78 四种比例，
    /// 但它们都不比面板（1.78）更宽，所以必须以面板比例为基准判断。
    static func looksNotched(_ modes: [CGDisplayMode], panelAspect: Double) -> Bool {
        let tolerance = 0.005
        var fillsPanel = Set<Int>()
        var widerThanPanel = Set<Int>()
        for mode in modes where mode.width > 0 && mode.pixelWidth == mode.width * 2 {
            let aspect = Double(mode.width) / Double(mode.height)
            if abs(aspect - panelAspect) <= tolerance {
                fillsPanel.insert(mode.width)
            } else if aspect > panelAspect + tolerance {
                widerThanPanel.insert(mode.width)
            }
        }
        return !fillsPanel.isDisjoint(with: widerThanPanel)
    }

    static func nativePixelSize(of modes: [CGDisplayMode]) -> (width: Int, height: Int)? {
        guard let native = modes
            .filter({ $0.ioFlags & nativeFlag != 0 })
            .map({ ($0.pixelWidth, $0.pixelHeight) })
            .max(by: { $0.0 * $0.1 < $1.0 * $1.1 }),
            native.1 > 0 else { return nil }
        return (native.0, native.1)
    }

    /// 切换分辨率。写入系统显示配置，效果等同在系统设置里改，重启后保持。
    static func setMode(_ mode: CGDisplayMode, for id: CGDirectDisplayID) -> CGError {
        var cfg: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&cfg)
        guard begin == .success, let config = cfg else { return begin }

        let err = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            return err
        }
        return CGCompleteDisplayConfiguration(config, .permanently)
    }

    /// 枚举可选的 Retina 档位。
    ///
    /// - 只保留 HiDPI 模式（像素 = 逻辑 × 2）
    /// - 按缩放比例筛选：`缩放% = 面板像素宽 / 逻辑宽`
    /// - 同一逻辑分辨率有多个刷新率时保留最高的
    /// - 当前档位即使落在范围外也保留，否则用户看不出自己在哪一档
    ///
    /// 注意不能用「渲染像素是否超过面板」来筛：4K 屏的 2560×1440 需要 5120×2880 缓冲，
    /// 像素确实超过面板，但那正是 150% 缩放的合法档位。
    static func retinaOptions(for id: CGDirectDisplayID,
                              scaleLow: Int,
                              scaleHigh: Int) -> [ResolutionOption] {
        let modes = allModes(for: id)
        guard let native = nativePixelSize(of: modes) else { return [] }

        let panelWidth = native.width
        let panelHeight = native.height
        let panelAspect = Double(panelWidth) / Double(panelHeight)
        // 刘海只存在于 MacBook 内屏。NSScreen 会滞后，模式列表特征更可靠，两者取或
        let notched = CGDisplayIsBuiltin(id) != 0
            && (Screens.hasNotch(id) || looksNotched(modes, panelAspect: panelAspect))
        let current = currentMode(for: id)

        func makeOption(_ mode: CGDisplayMode) -> ResolutionOption {
            // 宽高比大于面板 → 高度方向放不下，上下留黑边，刘海正好落进黑边里
            let aspect = Double(mode.width) / Double(mode.height)
            let isNoNotch = notched && aspect > panelAspect + 0.005
            let isCurrent = current.map {
                $0.width == mode.width && $0.height == mode.height && $0.pixelWidth == mode.pixelWidth
            } ?? false
            return ResolutionOption(
                // 带上像素宽：同一逻辑分辨率可能同时存在 Retina 与非 Retina 两种模式
                id: "\(mode.width)x\(mode.height)@\(mode.pixelWidth)",
                width: mode.width,
                height: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                scalePercent: Int((Double(panelWidth) / Double(mode.width) * 100).rounded()),
                isNoNotch: isNoNotch,
                isHiDPI: mode.pixelWidth == mode.width * 2,
                isCurrent: isCurrent,
                mode: mode
            )
        }

        var best: [String: CGDisplayMode] = [:]
        for mode in modes {
            guard mode.width > 0,
                  mode.pixelWidth == mode.width * 2,
                  mode.pixelHeight == mode.height * 2 else { continue }
            let scale = Double(panelWidth) / Double(mode.width) * 100
            guard scale >= Double(scaleLow), scale <= Double(scaleHigh) else { continue }
            let key = "\(mode.width)x\(mode.height)"
            if let existing = best[key], existing.refreshRate >= mode.refreshRate { continue }
            best[key] = mode
        }

        var result = best.values.map(makeOption).sorted {
            $0.width * $0.height > $1.width * $1.height
        }

        if let current, !result.contains(where: { $0.isCurrent }),
           let match = modes.first(where: {
               $0.width == current.width && $0.height == current.height && $0.pixelWidth == current.pixelWidth
           }) {
            result.append(makeOption(match))
        }
        return result
    }
}
