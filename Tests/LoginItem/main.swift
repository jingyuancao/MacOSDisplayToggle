// 登录项策略回归测试。
//
// 只测纯判断：哪条路径算 /Applications 里的安装版、系统状态怎么映射成界面状态、
// 启动时该不该刷新登录项。真正的 SMAppService 调用和面板手感靠真机验证，
// 这里不拿假系统 API 冒充。

import Foundation
import ServiceManagement

var failures = 0

func check(_ name: String, _ passes: Bool) {
    if passes {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)")
    }
}

print("安装版路径判定")

check("/Applications/MacOSDisplayToggle.app 是安装版",
      LoginItemPolicy.isInstalledApp(bundlePath: "/Applications/MacOSDisplayToggle.app"))

// URL 解析要吃掉末尾斜杠，否则人为拼出来的路径会被误判成开发版
check("末尾的斜杠不影响判定",
      LoginItemPolicy.isInstalledApp(bundlePath: "/Applications/MacOSDisplayToggle.app/"))

// .. 必须按路径语义消掉，不能靠字符串前缀匹配
check("含 .. 的等价路径仍是安装版",
      LoginItemPolicy.isInstalledApp(bundlePath: "/Applications/../Applications/MacOSDisplayToggle.app"))

check("build/ 下的同名 App 不是安装版",
      !LoginItemPolicy.isInstalledApp(
          bundlePath: "/Users/example/Tools/MacOSDisplayToggle/build/MacOSDisplayToggle.app"))

check("~/Applications 下的副本不是安装版",
      !LoginItemPolicy.isInstalledApp(bundlePath: "/Users/example/Applications/MacOSDisplayToggle.app"))

check("/tmp 下的副本不是安装版",
      !LoginItemPolicy.isInstalledApp(bundlePath: "/tmp/MacOSDisplayToggle.app"))

// 前缀相同但目录不同，不能误伤
check("/Applications 下的另一个 App 不是它",
      !LoginItemPolicy.isInstalledApp(bundlePath: "/Applications/MacOSDisplayToggleOther.app"))

print("系统状态映射")

check("已启用 → 开启",
      LoginItemPolicy.state(systemStatus: .enabled, installed: true) == .on)
check("未注册 → 关闭",
      LoginItemPolicy.state(systemStatus: .notRegistered, installed: true) == .off)
check("系统里找不到 → 关闭",
      LoginItemPolicy.state(systemStatus: .notFound, installed: true) == .off)
check("需要用户批准 → 需审批",
      LoginItemPolicy.state(systemStatus: .requiresApproval, installed: true) == .needsApproval)

// 开发版必须压过系统状态：即使在系统里显示已启用，这块面板也不该允许操作
check("开发版即使系统显示已启用也判为不可用",
      LoginItemPolicy.state(systemStatus: .enabled, installed: false) == .unavailable)
check("开发版即使需要批准也判为不可用",
      LoginItemPolicy.state(systemStatus: .requiresApproval, installed: false) == .unavailable)

// 界面开关只看这一个判定，不在视图和命令行里各写一遍
check("已开启在界面上算开", LoginItemState.on.isEnabled)
check("需审批在界面上也算开（只差系统放行）", LoginItemState.needsApproval.isEnabled)
check("关闭在界面上不算开", !LoginItemState.off.isEnabled)
check("不可用在界面上不算开", !LoginItemState.unavailable.isEnabled)

print("启动自愈")

// 只有在「本来就开着」时才重新注册，绝不能顺手打开用户没开的登录项
check("已开启时才刷新", LoginItemPolicy.shouldRefreshOnLaunch(.on))
check("关闭时不刷新", !LoginItemPolicy.shouldRefreshOnLaunch(.off))
check("需审批时不刷新（尊重用户已经做的选择）",
      !LoginItemPolicy.shouldRefreshOnLaunch(.needsApproval))
check("开发版不刷新", !LoginItemPolicy.shouldRefreshOnLaunch(.unavailable))

print("autostart 参数解析")

// 脚本需要幂等：不带参数只看状态，on/off 反复执行结果一致
check("不带参数 → 查看状态", AutostartCLI.parse([]) == .status)
check("status → 查看状态", AutostartCLI.parse(["status"]) == .status)
check("on → 开启", AutostartCLI.parse(["on"]) == .on)
check("off → 关闭", AutostartCLI.parse(["off"]) == .off)
check("未知动作 → 非法", AutostartCLI.parse(["enable"]) == .invalid("enable"))
check("大小写不宽容 → 非法", AutostartCLI.parse(["ON"]) == .invalid("ON"))
check("多余参数 → 非法", AutostartCLI.parse(["on", "extra"]) == .invalid("extra"))
check("空字符串 → 非法", AutostartCLI.parse([""]) == .invalid(""))

print("登录项控制器")

/// 假后端：只记录调用次数，不碰系统。
final class FakeLoginItem: LoginItemService {
    var state: LoginItemState
    var enableCalls = 0
    var disableCalls = 0
    var enableError: Error?

    init(_ state: LoginItemState) { self.state = state }

    func currentState() -> LoginItemState { state }

    func enable() throws {
        enableCalls += 1
        if let error = enableError { throw error }
        state = .on
    }

    func disable() throws {
        disableCalls += 1
        state = .off
    }

    func openSettings() {}
}

let installed = FakeLoginItem(.off)
let model = LoginItemController(service: installed)
check("初始状态来自系统", model.state == .off)
check("开启调用一次系统", model.setOn(true) && installed.enableCalls == 1 && model.state == .on)
check("关闭调用一次系统", model.setOn(false) && installed.disableCalls == 1 && model.state == .off)
check("成功后不留错误文本", model.errorText == nil)

let unavailable = FakeLoginItem(.unavailable)
let blocked = LoginItemController(service: unavailable)
check("不可用时开启被拒绝", blocked.setOn(true) == false)
check("不可用时一次系统调用都不发", unavailable.enableCalls == 0)
check("不可用时给出原因", blocked.errorText?.isEmpty == false)
check("不可用时状态仍为不可用", blocked.state == .unavailable)

let failing = FakeLoginItem(.off)
failing.enableError = LoginItemError.system("register 被拒绝")
let failingModel = LoginItemController(service: failing)
check("系统调用失败时返回失败", failingModel.setOn(true) == false)
check("系统调用失败时显示原因", failingModel.errorText?.contains("register 被拒绝") == true)
check("系统调用失败时不假装成功", failingModel.state == .off)

failingModel.refresh()
check("重新读系统后清掉旧错误", failingModel.errorText == nil)

// 启动自愈：只有本来开着才刷新，其余一律不碰系统
let heal = FakeLoginItem(.on)
LoginItemController(service: heal).reconcileOnLaunch()
check("已开启时启动刷新一次", heal.enableCalls == 1)

let closed = FakeLoginItem(.off)
LoginItemController(service: closed).reconcileOnLaunch()
check("未开启时启动不碰系统", closed.enableCalls == 0)

let pending = FakeLoginItem(.needsApproval)
LoginItemController(service: pending).reconcileOnLaunch()
check("需审批时启动不碰系统", pending.enableCalls == 0)

// 用户在系统设置里改了状态，面板重新读系统
installed.state = .on
model.refresh()
check("刷新能看到系统里的外部改动", model.state == .on)

print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
