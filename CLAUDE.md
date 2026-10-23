# CLAUDE.md

MacOSDisplayToggle：外接屏一线通时，用私有 SkyLight 接口决定哪块屏参与显示、切换 Retina 档位。
Apple Silicon + macOS 13+，纯 Swift，`swiftc` 直接编译，无第三方依赖。

用户向的原理与限制见 `README.md`；本文件只写改代码时的约束和入口。

## 命令

| 命令 | 用途 |
| --- | --- |
| `./build.sh` | 构建到 `build/`，不碰正在运行的 App |
| `./build.sh --install` | 装到 `/Applications` 并重启顶栏 App；会杀掉运行中的实例，执行前先确认 |
| `./scripts/test-blackout.sh` | 黑屏判定回归测试；改 `BlackoutJudge` / `externalLink` 后必跑 |
| `./scripts/test-login-item.sh` | 登录项策略回归测试；改 `LoginItemPolicy` / `autostart` 后必跑 |
| `./scripts/probe-displays.sh` | 只读信号探针；排查拔线、幽灵屏时用 |
| `macosdisplaytoggle status` | 查看当前显示器与开关状态 |

## 底线

改显示相关代码前，逐条确认：

1. **先开后关**：关一块屏之前，先确认还有一块屏真正在线；关完若一块不剩，立即回滚。任何时刻都不能把用户留在全黑里。
2. **黑屏只信 IOKit 链路**：`Screens.externalLink()` 是「外接屏还在不在」的唯一可信信号。拔线后 `online`、`active`、`NSScreen` 都会残留新 ID 的**幽灵屏**或陈旧数据（实测约 19.5 秒），不要用它们判断有没有画面。
3. **`nil` 只表示查询失败**：`externalLink()` 查询成功但没有任何 `DCPAVServiceProxy` 时必须返回 `false`（无外接链路）。这个区分就是拔线兜底的关键。
4. **CGError 不是判据**：重复提交常返回 1001 但已生效，以复查在线列表为准。
5. **合盖不救援**：内屏离线但 `state.disabled` 里没有记录（不是本工具关的），交给系统。

## 架构入口

- 系统接口：`Sources/DisplayAPI.swift`（无状态）
- 业务状态：`Sources/DisplayStore.swift`（下线记录、开关、恢复、救援）
- 黑屏判定：`Sources/BlackoutJudge.swift`（纯函数，`BlackoutSignals` 注入）
- 登录时启动：`Sources/LoginItem.swift`（路径策略、状态映射、CLI 解析、`SMAppService` 接缝）
- UI：`Sources/Panel.swift`
- 入口与看门狗：`Sources/main.swift`
- 日志：`Sources/EventLog.swift` → `~/Library/Logs/MacOSDisplayToggle/events.log`
- 版本号：`Sources/Version.swift`

完整机制见 `README.md` 的「源码结构」和「原理」。

## 约定

- 注释用中文，写「为什么」和踩过的坑；不要复述代码字面。
- 保持 `swiftc` 直接编译，不引入 SwiftPM、Xcode 工程或第三方依赖。
- 单一二进制同时是 CLI 和顶栏 App；新增入口先分清走哪条路径。
- 状态文件：`~/Library/Application Support/MacOSDisplayToggle/state.json`。CLI 与 App 是两个进程，靠文件 mtime 同步。
- 提交信息用中文，格式 `<type>: <摘要>`（如 `fix:`、`docs:`）；一次提交只做一件事。
- 发版：只改 `Version.swift` 的 `number`，并在 README「版本说明」记一条。

## 验证

- 判定逻辑：`./scripts/test-blackout.sh` 必须红→绿；新增判定分支时补用例。
- 登录项逻辑：`./scripts/test-login-item.sh` 必须红→绿；只测纯判断，`SMAppService` 的实际调用靠真机对照 `sfltool dumpbtm`。
- 真机行为：本机就是测试机。测试拔线/关屏时，手边留好外接线的插回路径，不要让自己处于无屏状态。
- 排查黑屏：先读 `events.log`，再用 `probe-displays.sh` 对照 `online / active / ws / externalLink`。
