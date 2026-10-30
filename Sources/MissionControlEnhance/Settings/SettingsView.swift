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
            window.title = String(localized: "MissionControlEnhance Settings")
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
            launchError = String(localized: "Failed to update: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var state: SettingsState
    @ObservedObject var fingers: FingerProbeModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    Toggle("Enabled", isOn: $prefs.enabled)
                    Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: state.setLaunchAtLogin))
                    if let launchError = state.launchError {
                        Text(launchError).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("App Icon") {
                    LabeledContent("Size") {
                        Slider(value: $prefs.iconSize, in: 24...64, step: 2)
                        Text("\(Int(prefs.iconSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    LabeledContent("Position") {
                        HStack(spacing: 12) {
                            Text(prefs.iconPosition.title).foregroundStyle(.secondary)
                            IconPositionPicker(selection: $prefs.iconPosition)
                        }
                    }
                }

                Section("Window Buttons (shown on hover)") {
                    Toggle("Show buttons", isOn: $prefs.showButtons)
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
                        LabeledContent("Preview (left to right)") {
                            HStack(spacing: 6) {
                                ForEach(prefs.enabledButtons) { ButtonSwatch(kind: $0) }
                            }
                        }
                    }
                    .disabled(!prefs.showButtons)
                    Toggle("Click again to confirm before quitting an app", isOn: $prefs.confirmQuit)
                }

                Section("Quick Actions") {
                    Toggle("Middle click", isOn: $prefs.middleClickEnabled)
                    if prefs.middleClickEnabled {
                        Picker("Middle click action", selection: $prefs.middleClickAction) {
                            ForEach(QuickAction.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Toggle("Three-finger trackpad press", isOn: $prefs.threeFingerClickEnabled)
                        .disabled(!FingerCountTracker.shared.isAvailable)
                    if prefs.threeFingerClickEnabled {
                        Picker("Three-finger press action", selection: $prefs.threeFingerClickAction) {
                            ForEach(QuickAction.allCases) { Text($0.title).tag($0) }
                        }
                        FingerCountProbe(model: fingers)
                    }
                    if !FingerCountTracker.shared.isAvailable {
                        Text("The multitouch framework can't be loaded on this system, so three-finger press is unavailable.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Excluded Apps") {
                    ForEach(prefs.excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(Self.appName(for: bundleID))
                            Spacer()
                            Button("Remove") { prefs.excludedBundleIDs.removeAll { $0 == bundleID } }
                        }
                    }
                    Menu("Add Running App") {
                        ForEach(Self.runningApps(excluding: prefs.excludedBundleIDs), id: \.0) { bundleID, name in
                            Button(name) { prefs.excludedBundleIDs.append(bundleID) }
                        }
                    }
                }

                Section("Diagnostics") {
                    Toggle("Debug mode (show match boxes and confidence)", isOn: $prefs.debugMode)
                    LabeledContent {
                        Button("Export") { DockTreeExporter.export(after: 3) }
                    } label: {
                        Text("Export Dock AX tree")
                        Text("Open Mission Control within 3 seconds after clicking. The result is saved to ~/Library/Logs/MissionControlEnhance")
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Version \(Self.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 480, height: 520)
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

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
                .help("Move left")
            Button { move(1) } label: { Image(systemName: "arrow.right") }
                .disabled(!canMoveRight)
                .help("Move right")
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
            Text("Rest your fingers on the trackpad to test. Fingers detected: \(model.count)")
                .monospacedDigit()
            if !model.inputMonitoring {
                HStack {
                    Text("If it stays at 0 while touching, Input Monitoring permission may be needed.").font(.caption).foregroundStyle(.secondary)
                    Button("Grant Access") {
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
