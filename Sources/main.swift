// main.swift — MacOSDisplayToggle 入口。同一个二进制，两种形态：
//   • 无参数 → 顶栏常驻 App（点开是显示器面板）
//   • status | only | all | toggle → 命令行工具

import AppKit
import SwiftUI
import Foundation

// MARK: - 命令行

enum CLI {
    private static let commands = ["status", "only", "all", "toggle", "version", "--version", "-v",
                                   "help", "--help", "-h"]

    static func shouldHandle(_ args: [String]) -> Bool {
        args.count > 1 && commands.contains(args[1])
    }

    static func run(_ args: [String]) -> Int32 {
        let store = DisplayStore.shared

        switch args[1] {
        case "version", "--version", "-v":
            print("MacOSDisplayToggle \(AppVersion.full)")
            return 0

        case "status":
            print("MacOSDisplayToggle \(AppVersion.full)")
            printStatus(store)
            return 0

        case "only":
            return report(store.disableAllExternals(),
                          success: "已关闭全部外接屏，仅保留内屏（充电不受影响）",
                          failurePrefix: "切换失败")

        case "all":
            return report(store.restoreAll(),
                          success: "已恢复全部显示器",
                          failurePrefix: "恢复失败")

        case "toggle":
            if store.hasExternalEnabled {
                return report(store.disableAllExternals(),
                              success: "已关闭外接屏，仅保留内屏",
                              failurePrefix: "切换失败")
            }
            return report(store.restoreAll(),
                          success: "已恢复外接屏",
                          failurePrefix: "切换失败")

        default:
            printHelp()
            return 0
        }
    }

    private static func printStatus(_ store: DisplayStore) {
        for item in store.snapshot() {
            let kind = item.isBuiltin ? "内屏" : "外接屏"
            var line = "  \(item.isEnabled ? "●" : "○") \(item.name)  [\(kind)] "
            line += item.isEnabled ? "显示中" : "已关闭"

            if item.isEnabled, let mode = ModeCatalog.currentMode(for: CGDirectDisplayID(item.id)) {
                line += "  \(mode.width)×\(mode.height)"
            }
            print(line)
        }
    }

    private static func report(_ result: Result<Void, DisplayError>,
                               success: String,
                               failurePrefix: String) -> Int32 {
        switch result {
        case .success:
            print(success)
            return 0
        case .failure(let error):
            print("\(failurePrefix)：\(error.errorDescription ?? "未知错误")")
            return 1
        }
    }

    private static func printHelp() {
        print("""
        MacOSDisplayToggle \(AppVersion.full) — 外接屏一线通时，自由决定哪块屏用于显示

        用法：
          MacOSDisplayToggle status    列出所有显示器及当前分辨率
          MacOSDisplayToggle only      关闭全部外接屏，只留内屏（充电照常）
          MacOSDisplayToggle all       恢复所有显示器
          MacOSDisplayToggle toggle    在两者之间切换
          MacOSDisplayToggle version   显示版本号

        不带参数运行则启动顶栏图标。
        """)
    }
}

// MARK: - 顶栏 App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PanelModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    /// 连续多少次检测到黑屏。要求连续两次才救援，
    /// 避免拔插、唤醒过程中的瞬时状态把用户特意关掉的内屏又打开。
    private var blackoutStreak = 0

    /// 阻止 App Nap。顶栏 App 没有可见窗口，黑屏时系统更会认为它「不可见」而节流定时器，
    /// 守护就会迟迟不执行——这正是守护要工作的时刻。
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "守护「至少一块屏幕可用」")

        setUpStatusItem()
        setUpPopover()

        model.refresh(force: true)
        updateIcon()
        EventLog.write("启动 \(AppVersion.full)；在线 \(EventLog.displaySummary())")

        // 每秒做一次底线巡检；面板收起时顺带同步状态（用户可能通过命令行或系统设置改了状态）
        var tick = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.guardAgainstBlackout()
            tick += 1
            guard tick % 2 == 0, !self.popover.isShown else { return }
            self.model.refresh()
            self.updateIcon()
        }
        timer.tolerance = 0.1
        RunLoop.current.add(timer, forMode: .common)

        // 拓扑变化（拔插线、启停显示器）时记录，并尽快巡检
        CGDisplayRegisterReconfigurationCallback({ display, flags, userInfo in
            guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { delegate.handleReconfiguration(display, flags) }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func handleReconfiguration(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
        var tags: [String] = []
        if flags.contains(.addFlag) { tags.append("接入"); DisplayStore.shared.noteDisplayAdded(display) }
        if flags.contains(.removeFlag) { tags.append("移除"); DisplayStore.shared.noteDisplayRemoved(display) }
        if flags.contains(.enabledFlag) { tags.append("启用"); DisplayStore.shared.noteDisplayAdded(display) }
        if flags.contains(.disabledFlag) { tags.append("停用") }
        guard !tags.isEmpty else { return }

        EventLog.write("拓扑变化：显示器 \(display) \(tags.joined(separator: "/"))；在线 \(EventLog.displaySummary())")
        for delay in [0.8, 2.0, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.guardAgainstBlackout() }
        }
    }

    /// 底线：任何时刻至少一块屏可见。典型场景是「只用外屏」时拔掉一线通。
    private func guardAgainstBlackout() {
        guard let reason = DisplayStore.shared.blackoutReason() else {
            blackoutStreak = 0
            return
        }
        blackoutStreak += 1
        if blackoutStreak == 1 {
            EventLog.write("疑似黑屏（等待确认）：\(reason)")
            return
        }

        blackoutStreak = 0
        DisplayStore.shared.rescueFromBlackout(reason: reason)
        model.refresh(force: true)
        updateIcon()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "MacOSDisplayToggle")
        button.image?.isTemplate = true
        button.toolTip = "MacOSDisplayToggle \(AppVersion.short)"
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func setUpPopover() {
        let hosting = NSHostingController(rootView: PanelView(model: model))
        hosting.sizingOptions = NSHostingSizingOptions.preferredContentSize

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hosting
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        model.refresh(force: true)
        updateIcon()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateIcon() {
        let symbol = model.hasExternalEnabled ? "rectangle.on.rectangle" : "laptopcomputer"
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "MacOSDisplayToggle")
        statusItem.button?.image?.isTemplate = true
    }
}

// MARK: - 入口

if CLI.shouldHandle(CommandLine.arguments) {
    exit(CLI.run(CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
