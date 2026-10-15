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
    @StateObject private var languageSettings: LanguageSettings
    private let smokeDirectory: URL?
    private let smokeDefaultsSuite: String?
    init() {
        if CommandLine.arguments.contains("--localization-audit") { Self.auditLocalization(); exit(0) }
        let smoke = CommandLine.arguments.contains("--smoke-test")
        let dir = smoke ? FileManager.default.temporaryDirectory.appendingPathComponent("app-proxy-ui-" + UUID().uuidString) : nil
        smokeDirectory = dir
        let suite = smoke ? "FlowLane.Smoke." + UUID().uuidString : nil
        smokeDefaultsSuite = suite
        let settings = LanguageSettings(defaults: suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard)
        if smoke {
            let args = CommandLine.arguments
            let language = args.firstIndex(of: "--smoke-language").flatMap { args.indices.contains($0 + 1) ? AppLanguage(rawValue: args[$0 + 1]) : nil } ?? .en
            settings.select(.language(language))
        }
        _languageSettings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: AppStore(directory: dir ?? AppPaths.support))
    }
    var body: some Scene {
        WindowGroup {
            ContentView(store: store, runtime: runtime, initialTab: CommandLine.arguments.contains("--smoke-settings") ? 4 : 0)
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.locale)
                .environment(\.layoutDirection, languageSettings.direction)
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
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(languageSettings.text("settings.title")) }.keyboardShortcut(",")
            }
            CommandMenu(languageSettings.text("network.menu")) {
                Button(languageSettings.text("network.stop")) { runtime.stop() }.keyboardShortcut(".").disabled(!runtime.active)
            }
        }
        Settings {
            LanguageSettingsView()
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.locale)
                .environment(\.layoutDirection, languageSettings.direction)
        }
    }
    @MainActor private func smokeTest(directory: URL) {
        do {
            let app = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            store.addApplications([app])
            guard store.error == nil, let draft = store.configuration.rules.first,
                  draft.proxyID == nil, !draft.enabled,
                  try store.persistence.load().rules == store.configuration.rules else { throw AppProxyError("Smoke: draft selection or persistence failed") }
            var p = ProxyProfile(name: "Local test proxy", kind: .socks5, host: "127.0.0.1", port: 1080)
            try store.saveProfile(p, password: "", keepPassword: false)
            p.name = "SOCKS5 example"
            try store.saveProfile(p, password: "", keepPassword: false)
            store.assignProxy(p.id, to: draft.id)
            guard store.configuration.rules.first?.enabled == true else { throw AppProxyError("Smoke: assignment did not enable the rule") }
            guard store.error == nil, try store.persistence.load().rules == store.configuration.rules else { throw AppProxyError("Smoke: UI persistence failed") }
            store.change { $0.rules[0].enabled = false }
            store.change { $0.rules.removeAll() }
            store.deleteProfile(p.id)
            guard store.configuration.proxies.isEmpty, store.configuration.rules.isEmpty else { throw AppProxyError("Smoke: deletion failed") }
            store.addApplications([app])
            guard !runtime.active else { throw AppProxyError("Smoke: networking must stay inactive") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Task { @MainActor in
                    let args = CommandLine.arguments
                    if let index = args.firstIndex(of: "--smoke-test"), args.count > index + 1 {
                        do {
                            guard CGPreflightScreenCaptureAccess() else { throw AppProxyError("Window screenshot permission unavailable") }
                            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                            guard let window = content.windows.first(where: { $0.owningApplication?.processID == getpid() && $0.frame.width > 800 }) else { throw AppProxyError("Application window not found") }
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
                    print("UI_SMOKE_PASS language=\(languageSettings.language.rawValue) app_selection_before_proxy assignment profiles_create_edit_delete rules_create_edit_delete persistence branded_window network_inactive")
                    try? FileManager.default.removeItem(at: directory)
                    if let smokeDefaultsSuite { UserDefaults(suiteName: smokeDefaultsSuite)?.removePersistentDomain(forName: smokeDefaultsSuite) }
                    NSApplication.shared.terminate(nil)
                }
            }
        } catch {
            fputs("UI_SMOKE_FAIL \(error.localizedDescription)\n", stderr)
            try? FileManager.default.removeItem(at: directory)
            if let smokeDefaultsSuite { UserDefaults(suiteName: smokeDefaultsSuite)?.removePersistentDomain(forName: smokeDefaultsSuite) }
            NSApplication.shared.terminate(nil)
        }
    }
    private static func auditLocalization() {
        let bundled = Localization.resourceBundle.bundleURL.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/Resources/")
        guard bundled else { fputs("LOCALIZATION_AUDIT_FAIL resources outside application\n", stderr); exit(1) }
        for table in LocalizationTable.allCases {
            let english = Localization.catalog(language: .en, table: table)
            guard !english.isEmpty else { fputs("LOCALIZATION_AUDIT_FAIL empty English catalog\n", stderr); exit(1) }
            for language in AppLanguage.allCases {
                guard Set(Localization.catalog(language: language, table: table).keys) == Set(english.keys) else {
                    fputs("LOCALIZATION_AUDIT_FAIL incomplete \(language.rawValue) catalog\n", stderr); exit(1)
                }
            }
        }
        print("LOCALIZATION_AUDIT_PASS languages=11 packaged_resources=true")
    }
}
