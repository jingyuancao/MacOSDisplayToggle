// Panel.swift — 顶栏弹出面板的视图与视图模型

import AppKit
import SwiftUI
import Foundation

// MARK: - 缩放范围

enum ScaleRange {
    static let lowerBound = 100.0
    static let upperBound = 300.0
    static let step = 25.0
    static let defaultLow = 150.0
    static let defaultHigh = 200.0

    /// 滑块可停靠的位置：100 / 125 / … / 300
    static let marks = Array(stride(from: Int(lowerBound), through: Int(upperBound), by: Int(step)))
}

// MARK: - 视图模型

/// 拖拽起点。放在 model 而不是 View 的 @State，是因为直接用 swiftc 编译时拿不到 SwiftUI 的宏插件。
final class DragState {
    enum Knob { case low, high }
    var anchor: Double?
    var knob: Knob = .low
}

final class PanelModel: ObservableObject {
    @Published private(set) var items: [DisplayItem] = []
    @Published private(set) var resolutions: [UInt32: [ResolutionOption]] = [:]
    @Published var expandedDisplay: UInt32?
    @Published var errorText: String?

    @Published var scaleLow: Double = ScaleRange.defaultLow
    @Published var scaleHigh: Double = ScaleRange.defaultHigh

    let drag = DragState()

    /// 登录项状态归系统管，这里只负责展示与转发操作；每次打开面板重新读系统
    let loginItem = LoginItemController(service: SystemLoginItem(), log: EventLog.write)

    private let store = DisplayStore.shared

    var hasExternalEnabled: Bool {
        items.contains { !$0.isBuiltin && $0.isEnabled }
    }

    private enum Key {
        static let scaleLow = "scaleLowPercent"
        static let scaleHigh = "scaleHighPercent"
    }

    init() {
        loadScaleRange()
    }

    // MARK: 刷新

    /// - Parameter force: 为 true 时即使显示器列表没变也重算档位（打开面板、操作之后用）。
    ///   定时刷新只更新开关状态，不必每次都枚举上百个显示模式。
    func refresh(force: Bool = false) {
        let latest = store.snapshot()
        guard force || latest != items else { return }
        items = latest
        reloadResolutions()
    }

    /// 只对处于开启状态的显示器枚举档位——关闭的屏没有可切换的模式
    private func reloadResolutions() {
        let low = Int(scaleLow.rounded())
        let high = Int(scaleHigh.rounded())
        var next: [UInt32: [ResolutionOption]] = [:]
        for item in items where item.isEnabled {
            next[item.id] = ModeCatalog.retinaOptions(for: CGDirectDisplayID(item.id),
                                                       scaleLow: low, scaleHigh: high)
        }
        resolutions = next
    }

    // MARK: 操作

    func setEnabled(_ item: DisplayItem, _ enabled: Bool) {
        handle(store.setEnabled([item.id], enabled))
    }

    func applyResolution(_ option: ResolutionOption, to item: DisplayItem) {
        handle(store.setResolution(option, for: item.id))
    }

    func restoreAndQuit() {
        _ = store.restoreAll()
        NSApp.terminate(nil)
    }

    private func handle(_ result: Result<Void, DisplayError>) {
        if case .failure(let error) = result {
            errorText = error.errorDescription
        } else {
            errorText = nil
        }
        refresh(force: true)
    }

    // MARK: 缩放范围

    /// 松手后才生效，避免拖动过程中反复枚举模式
    func commitScaleRange() {
        let defaults = UserDefaults.standard
        defaults.set(scaleLow, forKey: Key.scaleLow)
        defaults.set(scaleHigh, forKey: Key.scaleHigh)
        reloadResolutions()
    }

    private func loadScaleRange() {
        let defaults = UserDefaults.standard
        // 改名前的设置存在旧的 Bundle ID 下，新域里没有时沿用旧值
        let legacy = ["io.github.jingyuancao.OnlyInternal", "com.erick.onlyinternal"]
            .compactMap { UserDefaults(suiteName: $0) }
        func value(_ key: String) -> Double? {
            if let v = defaults.object(forKey: key) as? Double { return v }
            return legacy.lazy.compactMap { $0.object(forKey: key) as? Double }.first
        }
        if let low = value(Key.scaleLow) { scaleLow = low }
        if let high = value(Key.scaleHigh) { scaleHigh = high }

        scaleLow = quantize(scaleLow)
        scaleHigh = quantize(scaleHigh)
        guard scaleLow < scaleHigh else {
            scaleLow = ScaleRange.defaultLow
            scaleHigh = ScaleRange.defaultHigh
            return
        }
    }

    private func quantize(_ value: Double) -> Double {
        let stepped = (value / ScaleRange.step).rounded() * ScaleRange.step
        return min(max(stepped, ScaleRange.lowerBound), ScaleRange.upperBound)
    }
}

// MARK: - 面板

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var loginItem: LoginItemController

    private enum Layout {
        static let width: CGFloat = 300
        static let horizontalPadding: CGFloat = 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("用于显示的显示器")
                Spacer(minLength: 8)
                Text(AppVersion.short)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, Layout.horizontalPadding)
                    .help("MacOSDisplayToggle \(AppVersion.full)")
            }
            .padding(.top, 12)
            .padding(.bottom, 4)

            VStack(spacing: 1) {
                ForEach(model.items) { item in
                    row(item)
                }
            }
            .padding(.top, 2)

            if let error = model.errorText {
                errorBanner(error)
            }

            Divider().padding(.top, 8)

            scaleRangeBar

            Divider()

            loginItemRow

            Divider()

            quitButton
        }
        .frame(width: Layout.width)
    }

    // MARK: 分区

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Layout.horizontalPadding)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.bottom, 8)
    }

    /// 登录时启动：状态是系统给的，界面如实反映，不在本地留副本
    private var loginItemRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("登录时启动")
                    .font(.system(size: 12))
                    .foregroundStyle(loginItem.state == .unavailable ? Color.secondary : Color.primary)
                Spacer(minLength: 8)
                PanelSwitch(isOn: loginItem.state.isEnabled) { on in
                    loginItem.setOn(on)
                }
                .opacity(loginItem.state == .unavailable ? 0.35 : 1)
                .allowsHitTesting(loginItem.state != .unavailable)
            }

            switch loginItem.state {
            case .needsApproval:
                Button("需在系统设置中允许") {
                    loginItem.openSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
            case .unavailable:
                Text("仅 /Applications 里的安装版可用")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .on, .off:
                EmptyView()
            }

            if let error = loginItem.errorText {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, 8)
    }

    private var quitButton: some View {
        Button {
            model.restoreAndQuit()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "power")
                Text("恢复全部显示器并退出")
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: 单台显示器

    private func row(_ item: DisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: item.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary.opacity(0.6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
                    Text(item.isBuiltin ? "内屏" : "外接屏")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                PanelSwitch(isOn: item.isEnabled) { enabled in
                    model.setEnabled(item, enabled)
                }
            }

            if item.isEnabled, let options = model.resolutions[item.id], !options.isEmpty {
                resolutionPicker(item, options)
                    .padding(.leading, 32)
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// 自绘下拉。系统 Menu 会被 .borderlessButton 样式接管（箭头位置、背景都变），
    /// 与面板风格不一致，所以这里展开成内嵌列表。
    private func resolutionPicker(_ item: DisplayItem, _ options: [ResolutionOption]) -> some View {
        let current = options.first(where: \.isCurrent)
        let expanded = model.expandedDisplay == item.id

        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.expandedDisplay = expanded ? nil : item.id
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current?.displayName ?? "选择分辨率")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        resolutionRow(option, item: item)
                    }
                }
                .padding(.top, 1)
            }
        }
    }

    private func resolutionRow(_ option: ResolutionOption, item: DisplayItem) -> some View {
        Button {
            model.applyResolution(option, to: item)
            withAnimation(.easeInOut(duration: 0.15)) { model.expandedDisplay = nil }
        } label: {
            HStack(spacing: 6) {
                Text(option.displayName)
                    .font(.system(size: 11))
                Spacer(minLength: 0)
                Text("\(option.scalePercent)%")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(option.isCurrent ? 1 : 0)
                    .frame(width: 12)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(option.isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 缩放范围滑块

    private var scaleRangeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("分辨率缩放范围")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int(model.scaleLow.rounded()))% – \(Int(model.scaleHigh.rounded()))%")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            GeometryReader { geometry in
                let knob: CGFloat = 15
                let usable = max(geometry.size.width - knob, 1)

                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.13))
                            .frame(height: 4)
                            .padding(.horizontal, knob / 2)

                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(knobX(model.scaleHigh, usable) - knobX(model.scaleLow, usable), 0),
                                   height: 4)
                            .offset(x: knobX(model.scaleLow, usable) + knob / 2)

                        ForEach(ScaleRange.marks, id: \.self) { mark in
                            tick(mark, usable: usable, knob: knob, y: 7.5)
                        }

                        handle.offset(x: knobX(model.scaleLow, usable))
                            .gesture(dragHandle(isLow: true, usable: usable))
                        handle.offset(x: knobX(model.scaleHigh, usable))
                            .gesture(dragHandle(isLow: false, usable: usable))
                    }
                    .frame(height: knob)

                    // 每个停靠点的数值，拖之前就能看清能停在哪
                    ForEach(ScaleRange.marks, id: \.self) { mark in
                        markLabel(mark, usable: usable, knob: knob)
                    }
                }
                .frame(height: knob + 15)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, 9)
    }

    private func tick(_ mark: Int, usable: CGFloat, knob: CGFloat, y: CGFloat) -> some View {
        let inside = Double(mark) >= model.scaleLow && Double(mark) <= model.scaleHigh
        return Rectangle()
            .fill(inside ? Color.white.opacity(0.5) : Color.primary.opacity(0.18))
            .frame(width: 1, height: 6)
            .position(x: knobX(Double(mark), usable) + knob / 2, y: y)
    }

    private func markLabel(_ mark: Int, usable: CGFloat, knob: CGFloat) -> some View {
        let inside = Double(mark) >= model.scaleLow && Double(mark) <= model.scaleHigh
        return Text("\(mark)")
            .font(.system(size: 8.5))
            .monospacedDigit()
            .foregroundStyle(inside ? Color.secondary : Color.secondary.opacity(0.55))
            .fixedSize()
            .position(x: knobX(Double(mark), usable) + knob / 2, y: knob + 8)
    }

    private var handle: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 15, height: 15)
            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
    }

    private func knobX(_ value: Double, _ usable: CGFloat) -> CGFloat {
        let span = ScaleRange.upperBound - ScaleRange.lowerBound
        let ratio = min(max((value - ScaleRange.lowerBound) / span, 0), 1)
        return CGFloat(ratio) * usable
    }

    private func dragHandle(isLow: Bool, usable: CGFloat) -> some Gesture {
        let span = ScaleRange.upperBound - ScaleRange.lowerBound
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if model.drag.anchor == nil {
                    model.drag.anchor = isLow ? model.scaleLow : model.scaleHigh
                    model.drag.knob = isLow ? .low : .high
                }
                guard model.drag.knob == (isLow ? .low : .high), let anchor = model.drag.anchor else { return }

                let delta = Double(value.translation.width) / Double(usable) * span
                // 吸附到 25% 的步进点
                var next = ((anchor + delta) / ScaleRange.step).rounded() * ScaleRange.step
                if isLow {
                    next = min(max(next, ScaleRange.lowerBound), model.scaleHigh - ScaleRange.step)
                    if next != model.scaleLow { model.scaleLow = next }
                } else {
                    next = min(max(next, model.scaleLow + ScaleRange.step), ScaleRange.upperBound)
                    if next != model.scaleHigh { model.scaleHigh = next }
                }
            }
            .onEnded { _ in
                model.drag.anchor = nil
                model.commitScaleRange()
            }
    }
}

// MARK: - 开关

/// 自绘开关。不用系统 Toggle 的原因：NSSwitch 经 AppKit 桥接，
/// 在离屏渲染与快速状态切换时会有一拍延迟，导致界面显示与实际状态不一致。
struct PanelSwitch: View {
    let isOn: Bool
    let action: (Bool) -> Void

    private let width: CGFloat = 34
    private let height: CGFloat = 20
    private let knobSize: CGFloat = 16

    var body: some View {
        Button {
            action(!isOn)
        } label: {
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.16))
                    .frame(width: width, height: height)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .offset(x: isOn ? (width - knobSize - 2) : 2)
            }
            .frame(width: width, height: height)
            .animation(.easeInOut(duration: 0.16), value: isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
