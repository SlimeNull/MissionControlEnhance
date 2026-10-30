import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let prefs: Preferences
    private var window: NSWindow?

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    func show() {
        if window == nil {
            let view = SettingsView(prefs: prefs, state: SettingsState(), fingers: FingerProbeModel())
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "MissionControlEnhance 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// View-local state. Kept in an ObservableObject because the Command Line Tools toolchain
/// ships without the SwiftUI macro plugins that `@State` requires.
@MainActor
final class SettingsState: ObservableObject {
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchError: String?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "设置失败：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var state: SettingsState
    @ObservedObject var fingers: FingerProbeModel

    var body: some View {
        Form {
            Section("通用") {
                Toggle("启用", isOn: $prefs.enabled)
                Toggle("登录时启动", isOn: Binding(get: { state.launchAtLogin }, set: state.setLaunchAtLogin))
                if let launchError = state.launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("应用图标") {
                LabeledContent("大小") {
                    Slider(value: $prefs.iconSize, in: 24...64, step: 2)
                    Text("\(Int(prefs.iconSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                LabeledContent("位置") {
                    HStack(spacing: 12) {
                        Text(prefs.iconPosition.title).foregroundStyle(.secondary)
                        IconPositionPicker(selection: $prefs.iconPosition)
                    }
                }
            }

            Section("窗口按钮（鼠标悬停时显示）") {
                Toggle("显示按钮", isOn: $prefs.showButtons)
                Group {
                    ForEach(Array(prefs.buttonOrder.enumerated()), id: \.element) { index, kind in
                        ButtonOrderRow(
                            kind: kind,
                            isShown: Binding(get: { prefs.isButtonShown(kind) }, set: { prefs.setButton(kind, shown: $0) }),
                            canMoveLeft: index > 0,
                            canMoveRight: index < prefs.buttonOrder.count - 1,
                            move: { prefs.moveButton(kind, by: $0) }
                        )
                    }
                    LabeledContent("预览（从左到右）") {
                        HStack(spacing: 6) {
                            ForEach(prefs.enabledButtons) { ButtonSwatch(kind: $0) }
                        }
                    }
                }
                .disabled(!prefs.showButtons)
                Toggle("退出应用前需要再次点击确认", isOn: $prefs.confirmQuit)
            }

            Section("快捷操作") {
                Toggle("鼠标中键点击", isOn: $prefs.middleClickEnabled)
                if prefs.middleClickEnabled {
                    Picker("中键点击动作", selection: $prefs.middleClickAction) {
                        ForEach(QuickAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle("触控板三指按下", isOn: $prefs.threeFingerClickEnabled)
                    .disabled(!FingerCountTracker.shared.isAvailable)
                if prefs.threeFingerClickEnabled {
                    Picker("三指按下动作", selection: $prefs.threeFingerClickAction) {
                        ForEach(QuickAction.allCases) { Text($0.title).tag($0) }
                    }
                    FingerCountProbe(model: fingers)
                }
                if !FingerCountTracker.shared.isAvailable {
                    Text("当前系统无法加载多点触控框架，三指按下不可用。").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("排除的应用") {
                ForEach(prefs.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(Self.appName(for: bundleID))
                        Spacer()
                        Button("移除") { prefs.excludedBundleIDs.removeAll { $0 == bundleID } }
                    }
                }
                Menu("添加正在运行的应用") {
                    ForEach(Self.runningApps(excluding: prefs.excludedBundleIDs), id: \.0) { bundleID, name in
                        Button(name) { prefs.excludedBundleIDs.append(bundleID) }
                    }
                }
            }

            Section("诊断") {
                Toggle("调试模式（显示匹配框与置信度）", isOn: $prefs.debugMode)
                LabeledContent {
                    Button("导出") { DockTreeExporter.export(after: 3) }
                } label: {
                    Text("导出 Dock AX 树")
                    Text("点击后 3 秒内打开调度中心，结果保存到 ~/Library/Logs/MissionControlEnhance")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
    }

    private static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private static func runningApps(excluding: [String]) -> [(String, String)] {
        let excluded = Set(excluding)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, !excluded.contains(id), seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }
}

/// A thumbnail outline with a dot on each corner, edge and the center; click a dot to place the icon there.
private struct IconPositionPicker: View {
    @Binding var selection: IconPosition

    private let size = CGSize(width: 88, height: 54)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.5)))
                .frame(width: size.width, height: size.height)
            ForEach(IconPosition.allCases) { position in
                Button { selection = position } label: {
                    Circle()
                        .fill(position == selection ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.7)))
                        .frame(width: 14, height: 14)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(position.title)
                .offset(x: CGFloat(position.column) * size.width / 2, y: CGFloat(position.row) * size.height / 2)
            }
        }
        .frame(width: size.width + 16, height: size.height + 16)
    }
}

private struct ButtonOrderRow: View {
    let kind: ButtonKind
    @Binding var isShown: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack {
            Toggle(isOn: $isShown) {
                HStack(spacing: 6) {
                    ButtonSwatch(kind: kind)
                    Text(kind.title)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button { move(-1) } label: { Image(systemName: "arrow.left") }
                .disabled(!canMoveLeft)
                .help("左移")
            Button { move(1) } label: { Image(systemName: "arrow.right") }
                .disabled(!canMoveRight)
                .help("右移")
        }
        .buttonStyle(.borderless)
    }
}

/// Settings-sized stand-in for the overlay button art.
private struct ButtonSwatch: View {
    let kind: ButtonKind

    var body: some View {
        let (color, symbol): (Color, String) = switch kind {
        case .close: (.red, "xmark")
        case .minimize: (.yellow, "minus")
        case .quit: (Color(white: 0.3), "power")
        }
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
    }
}

/// Live finger count, so users can check the private framework works on their machine.
@MainActor
final class FingerProbeModel: ObservableObject {
    @Published var count = 0
    @Published var inputMonitoring = Permissions.isInputMonitoringGranted
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        FingerCountTracker.shared.acquire()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.count = FingerCountTracker.shared.currentCount
                self?.inputMonitoring = Permissions.isInputMonitoringGranted
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        FingerCountTracker.shared.release()
    }
}

private struct FingerCountProbe: View {
    @ObservedObject var model: FingerProbeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("把手指放在触控板上测试，当前检测到 \(model.count) 根手指")
                .monospacedDigit()
            if !model.inputMonitoring {
                HStack {
                    Text("若触摸时始终为 0，可能需要“输入监控”权限。").font(.caption).foregroundStyle(.secondary)
                    Button("授权") {
                        Permissions.requestInputMonitoring()
                        Permissions.openInputMonitoringSettings()
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
