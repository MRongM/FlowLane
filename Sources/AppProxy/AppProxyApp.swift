import AppKit
import AppProxyKit
import ScreenCaptureKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: RuntimeController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { runtime?.shutdown() }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AppProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: AppStore
    @StateObject private var runtime = RuntimeController()
    private let smokeDirectory: URL?
    init() {
        let smoke = CommandLine.arguments.contains("--smoke-test")
        let dir = smoke ? FileManager.default.temporaryDirectory.appendingPathComponent("app-proxy-ui-" + UUID().uuidString) : nil
        smokeDirectory = dir
        _store = StateObject(wrappedValue: AppStore(directory: dir ?? AppPaths.support))
    }
    var body: some Scene {
        WindowGroup {
            ContentView(store: store, runtime: runtime)
                .frame(minWidth: 900, minHeight: 650)
                .onAppear {
                    delegate.runtime = runtime
                    if let smokeDirectory {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { smokeTest(directory: smokeDirectory) }
                    }
                }
        }
        .defaultSize(width: 1040, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("网络") {
                Button("停止网络接管") { runtime.stop() }.keyboardShortcut(".").disabled(!runtime.active)
            }
        }
    }
    @MainActor private func smokeTest(directory: URL) {
        do {
            var p = ProxyProfile(name: "本地测试代理", kind: .socks5, host: "127.0.0.1", port: 1080)
            try store.saveProfile(p, password: "", keepPassword: false)
            p.name = "SOCKS5 示例"
            try store.saveProfile(p, password: "", keepPassword: false)
            let app = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            let rule = try AppSelection.rule(for: app, proxyID: p.id)
            store.change { $0.rules.append(rule) }
            guard store.error == nil, try store.persistence.load().rules == store.configuration.rules else { throw AppProxyError("UI 持久化检查失败") }
            store.change { $0.rules[0].enabled = false }
            store.change { $0.rules.removeAll() }
            store.deleteProfile(p.id)
            guard store.configuration.proxies.isEmpty, store.configuration.rules.isEmpty else { throw AppProxyError("UI 删除检查失败") }
            try store.saveProfile(p, password: "", keepPassword: false)
            store.change { $0.rules.append(rule) }
            guard !runtime.active else { throw AppProxyError("UI 冒烟测试不能启用网络") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Task { @MainActor in
                    let args = CommandLine.arguments
                    if let index = args.firstIndex(of: "--smoke-test"), args.count > index + 1 {
                        do {
                            guard CGPreflightScreenCaptureAccess() else { throw AppProxyError("未获得窗口截图权限") }
                            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                            guard let window = content.windows.first(where: { $0.owningApplication?.processID == getpid() && $0.frame.width > 800 }) else { throw AppProxyError("未找到应用窗口") }
                            let filter = SCContentFilter(desktopIndependentWindow: window)
                            let configuration = SCStreamConfiguration()
                            configuration.width = Int(window.frame.width); configuration.height = Int(window.frame.height)
                            configuration.scalesToFit = true
                            configuration.showsCursor = false
                            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                            let bitmap = NSBitmapImageRep(cgImage: image)
                            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[index + 1]))
                        } catch { print("UI_SCREENSHOT_UNAVAILABLE " + error.localizedDescription) }
                    }
                    print("UI_SMOKE_PASS profiles_create_edit_delete rules_create_edit_delete persistence window_created network_inactive")
                    try? FileManager.default.removeItem(at: directory)
                    NSApplication.shared.terminate(nil)
                }
            }
        } catch {
            fputs("UI_SMOKE_FAIL \(error.localizedDescription)\n", stderr)
            try? FileManager.default.removeItem(at: directory)
            NSApplication.shared.terminate(nil)
        }
    }
}
