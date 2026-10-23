// LoginItem.swift — 「登录时启动」的判断逻辑与系统接缝
//
// 路径策略、状态映射、CLI 语法都是纯函数；SystemLoginItem 只做 SMAppService 的
// 薄适配，LoginItemController 把「当前状态 + 错误文本」收敛在一处，方便面板与命令行共用。

import AppKit
import Foundation
import ServiceManagement

/// 面板与命令行共享的登录项状态。
enum LoginItemState: Equatable {
    /// 未注册
    case off
    /// 已注册且系统允许
    case on
    /// 已注册，但用户在系统设置里关掉了，需要重新批准
    case needsApproval
    /// 当前不是 /Applications 里的安装版，不提供这个开关
    case unavailable

    /// 界面上的开关是否为「开」。需审批也算开：注册已经提交，只差系统放行。
    var isEnabled: Bool {
        self == .on || self == .needsApproval
    }
}

enum LoginItemPolicy {
    static let installedBundlePath = "/Applications/MacOSDisplayToggle.app"

    /// 只有 /Applications 里的安装版才允许操作登录项。
    ///
    /// 实测系统并不拦非安装版注册（/tmp 里也能注册成功），但 build/ 是随时会被
    /// 删掉的构建产物，把登录项绑到它上面会留下悬空记录，直到下次登录失败才被发现。
    static func isInstalledApp(bundlePath: String) -> Bool {
        canonical(bundlePath) == canonical(installedBundlePath)
    }

    /// 开发版压过系统状态：即使系统里显示已启用，也不是这个副本能管的事。
    static func state(systemStatus: SMAppService.Status, installed: Bool) -> LoginItemState {
        guard installed else { return .unavailable }
        switch systemStatus {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    /// 启动时只刷新「本来就开着」的登录项（register 幂等，实测可重复调用）。
    /// 其余状态一律不动，避免把用户在系统设置里关掉的东西又打开。
    static func shouldRefreshOnLaunch(_ state: LoginItemState) -> Bool {
        state == .on
    }

    /// 比较前先做路径语义归一：吃掉末尾斜杠、消掉 `..`、解析符号链接。
    /// 直接拿字符串前缀匹配会把 /Applications 下的同名目录也放进来。
    private static func canonical(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

// MARK: - 命令行契约

/// `autostart` 后面的参数。解析成动作之后才碰系统，方便脚本幂等调用。
enum AutostartCommand: Equatable {
    case status
    case on
    case off
    /// 带着用户写错的那个词，原样回显
    case invalid(String)
}

enum AutostartCLI {
    /// `arguments` 是 `autostart` 之后的参数，不含子命令本身。
    /// 不带参数等价 `status`；多写一个词一律报错，不猜用户想干什么。
    static func parse(_ arguments: [String]) -> AutostartCommand {
        guard let first = arguments.first else { return .status }
        guard arguments.count == 1 else { return .invalid(arguments[1]) }
        switch first {
        case "status": return .status
        case "on": return .on
        case "off": return .off
        default: return .invalid(first)
        }
    }
}

// MARK: - 接缝

/// App 与系统登录项之间的接缝。真实现包 SMAppService，测试注入假实现。
protocol LoginItemService {
    func currentState() -> LoginItemState
    func enable() throws
    func disable() throws
    func openSettings()
}

enum LoginItemError: LocalizedError {
    case unavailable
    case system(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "登录时启动仅对 /Applications 里的安装版可用"
        case .system(let message):
            return message
        }
    }
}

/// 真实现。只做 SMAppService 的三层薄调用，判断逻辑都在 LoginItemPolicy 里。
struct SystemLoginItem: LoginItemService {
    private let bundlePath: String
    private let service = SMAppService.mainApp

    init(bundlePath: String = Bundle.main.bundleURL.path) {
        self.bundlePath = bundlePath
    }

    func currentState() -> LoginItemState {
        // 先做路径判断，非安装版连 status 都不读：
        // 实测只要调用 SMAppService.mainApp.status，系统就会把 BTM 记录的 URL
        // 改写成当前这个副本。开发版查一次状态就可能把已开启的登录项指向 build/。
        guard LoginItemPolicy.isInstalledApp(bundlePath: bundlePath) else { return .unavailable }
        return LoginItemPolicy.state(systemStatus: service.status, installed: true)
    }

    func enable() throws {
        try requireInstalled()
        do {
            try service.register()
        } catch {
            throw LoginItemError.system(error.localizedDescription)
        }
    }

    func disable() throws {
        try requireInstalled()
        do {
            try service.unregister()
        } catch {
            throw LoginItemError.system(error.localizedDescription)
        }
    }

    func openSettings() {
        // 登录项设置页的 ExtensionKit 标识，已在本机确认存在
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    /// 系统本身不拦非安装版注册（实测 /tmp 也能注册成功），所以这一层必须自己拦，
    /// 否则登录项会指向一份随时被删掉的构建产物。
    private func requireInstalled() throws {
        guard LoginItemPolicy.isInstalledApp(bundlePath: bundlePath) else {
            throw LoginItemError.unavailable
        }
    }
}

// MARK: - 控制器

/// 面板与命令行共享的操作入口：把「当前状态 + 错误文本」收敛在一处。
final class LoginItemController: ObservableObject {
    @Published private(set) var state: LoginItemState
    @Published private(set) var errorText: String?

    private let service: LoginItemService
    private let log: (String) -> Void

    init(service: LoginItemService, log: @escaping (String) -> Void = { _ in }) {
        self.service = service
        self.log = log
        self.state = service.currentState()
    }

    /// 重新读系统。用户在系统设置里改过之后，下一次打开面板就能看到。
    /// 同时清掉上一次操作的错误：重新读到的状态才是准的，旧错误没有继续展示的意义。
    func refresh() {
        state = service.currentState()
        errorText = nil
    }

    /// 返回是否成功，命令行据此决定退出码；面板忽略返回值，只读 errorText。
    @discardableResult
    func setOn(_ on: Bool) -> Bool {
        guard state != .unavailable else {
            errorText = LoginItemError.unavailable.errorDescription
            log("登录项操作被拒：当前不是安装版")
            return false
        }

        do {
            if on { try service.enable() } else { try service.disable() }
            refresh()
            log(on ? "登录项已开启" : "登录项已关闭")
            return true
        } catch {
            // 先把状态读回系统，再挂错误，避免被 refresh 顺手清掉
            refresh()
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log("登录项操作失败：\(errorText ?? "未知错误")")
            return false
        }
    }

    /// 启动时刷新注册记录。换掉 App 后 ad-hoc 的 cdhash 会变，register 幂等，
    /// 重放一次就能把记录对上新二进制；但只对「本来就开着」的状态做。
    func reconcileOnLaunch() {
        guard LoginItemPolicy.shouldRefreshOnLaunch(state) else { return }
        do {
            try service.enable()
            log("登录项已在启动时刷新")
        } catch {
            log("登录项刷新失败：\(error.localizedDescription)")
        }
        refresh()
    }

    func openSettings() {
        service.openSettings()
    }
}
