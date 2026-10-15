import AppKit
import AppProxyKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var language: LanguageSettings
    private func t(_ key: String, _ arguments: String...) -> String { language.text(key, arguments: arguments) }
    @ObservedObject var store: AppStore
    @ObservedObject var runtime: RuntimeController
    @State private var tab: Int
    @State private var editor: ProxyProfile?
    @State private var showNewProxy = false

    init(store: AppStore, runtime: RuntimeController, initialTab: Int = 0) {
        self.store = store; self.runtime = runtime; _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let logo = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/FlowLane.png")) {
                    Image(nsImage: logo).resizable().frame(width: 48, height: 48)
                } else {
                    Image(systemName: "arrow.triangle.branch").font(.largeTitle).foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("brand.name")).font(.title2.bold())
                    Text(t("brand.tagline")).foregroundStyle(.secondary)
                }
                Spacer()
                Label(t("phase." + runtime.state.phase.rawValue), systemImage: runtime.state.phase == .running ? "circle.fill" : "circle")
                    .foregroundStyle(runtime.state.phase == .running ? .green : runtime.state.phase == .failed ? .red : .secondary)
                if runtime.active {
                    Button(t("network.stop"), role: .destructive) { runtime.stop() }.disabled(runtime.state.phase == .stopping)
                } else {
                    Button(t("network.start")) { runtime.start(store: store) }.buttonStyle(.borderedProminent)
                        .disabled(!store.loaded || !store.configuration.rules.contains(where: \.enabled))
                }
            }.padding(22)
            Divider()
            HStack {
                Text(language.render(runtime.state.content)).foregroundStyle(runtime.state.phase == .failed ? .red : .secondary).textSelection(.enabled)
                Spacer()
                Text("sing-box 1.14.3 · TCP").font(.caption).foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight)
            }.padding(.horizontal, 22).padding(.vertical, 12)
            TabView(selection: $tab) {
                rulesView.tabItem { Label(t("nav.apps"), systemImage: "app.badge.checkmark") }.tag(0)
                profilesView.tabItem { Label(t("nav.proxies"), systemImage: "server.rack") }.tag(1)
                logsView.tabItem { Label(t("nav.logs"), systemImage: "text.alignleft") }.tag(2)
                limitationsView.tabItem { Label(t("nav.help"), systemImage: "info.circle") }.tag(3)
                LanguageSettingsView().tabItem { Label(t("nav.settings"), systemImage: "gearshape") }.tag(4)
            }.padding([.horizontal, .bottom], 18)
        }
        .sheet(isPresented: $showNewProxy) { ProfileEditor(store: store, profile: ProxyProfile(name: "", kind: .socks5, host: "", port: 1080)) }
        .sheet(item: $editor) { ProfileEditor(store: store, profile: $0) }
        .alert(t("alert.failed"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(t("common.ok")) { store.error = nil }
        } message: { Text(store.error.map(language.render) ?? "") }
    }

    private var rulesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(t("nav.apps")).font(.title3.bold())
                    Text(t("apps.description")).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.selectApplication(language: language.language) } label: { Label(t("apps.add"), systemImage: "plus") }
                    .disabled(runtime.active || !store.loaded)
            }
            if store.configuration.rules.isEmpty {
                ContentUnavailableView(t("apps.empty_title"), systemImage: "app.dashed", description: Text(t("apps.empty_body")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(store.configuration.rules.enumerated()), id: \.element.id) { index, rule in
                            ruleRow(rule, index: index)
                        }
                    }.padding(4)
                }
            }
            Spacer(minLength: 0)
            Label(t("apps.authorization"), systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
        }.padding(18)
    }
    private func ruleRow(_ rule: ApplicationRule, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(index + 1, format: .number.grouping(.never)).monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
            Image(nsImage: NSWorkspace.shared.icon(forFile: rule.appPath)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: rule.name).font(.headline)
                Text(verbatim: rule.appPath).environment(\.layoutDirection, .leftToRight).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(t("apps.main_process", "\u{2066}" + rule.executablePath + "\u{2069}")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(rule.executablePath)
                if rule.proxyID == nil { Text(t("apps.unassigned_hint")).font(.caption).foregroundStyle(.secondary) }
                Toggle(t("apps.include_helpers"), isOn: ruleBinding(rule, \.includeHelpers)).font(.caption)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Picker(t("apps.proxy"), selection: Binding<UUID?>(get: {
                    store.configuration.rules.first(where: { $0.id == rule.id })?.proxyID
                }, set: { store.assignProxy($0, to: rule.id) })) {
                    Text(t("apps.unassigned")).tag(Optional<UUID>.none)
                    ForEach(store.configuration.proxies) { p in Text(verbatim: p.name).tag(Optional(p.id)) }
                }.frame(width: 220)
                HStack {
                    Toggle(t("apps.enabled"), isOn: ruleBinding(rule, \.enabled)).toggleStyle(.switch).controlSize(.small)
                        .disabled(rule.proxyID == nil)
                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.help(t("apps.move_up")).accessibilityLabel(t("apps.move_up")).disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.help(t("apps.move_down")).accessibilityLabel(t("apps.move_down")).disabled(index == store.configuration.rules.count - 1)
                    Button(role: .destructive) { store.change { $0.rules.removeAll { $0.id == rule.id } } } label: { Image(systemName: "trash") }.help(t("common.delete")).accessibilityLabel(t("common.delete"))
                }
            }
        }.padding(14).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10)).disabled(runtime.active)
    }
    private func ruleBinding<T>(_ rule: ApplicationRule, _ path: WritableKeyPath<ApplicationRule, T>) -> Binding<T> {
        Binding(get: { store.configuration.rules.first(where: { $0.id == rule.id })?[keyPath: path] ?? rule[keyPath: path] }, set: { value in
            store.change { c in if let i = c.rules.firstIndex(where: { $0.id == rule.id }) { c.rules[i][keyPath: path] = value } }
        })
    }
    private func move(_ index: Int, by offset: Int) { store.change { $0.rules.swapAt(index, index + offset) } }

    private var profilesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(t("nav.proxies")).font(.title3.bold()); Spacer()
                Button { showNewProxy = true } label: { Label(t("profiles.add"), systemImage: "plus") }.disabled(runtime.active || !store.loaded)
            }
            Text(t("profiles.intro")).foregroundStyle(.secondary)
            List(store.configuration.proxies) { p in
                HStack {
                    Image(systemName: "server.rack").foregroundStyle(.blue).font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: p.name).font(.headline)
                        Text(verbatim: "\(p.kind.title) · \(p.host):\(p.port)").environment(\.layoutDirection, .leftToRight).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p.hasPassword { Image(systemName: "key.fill").foregroundStyle(.secondary).help(t("profiles.password_saved")) }
                    Button(t("common.edit")) { editor = p }
                    Button(role: .destructive) { store.deleteProfile(p.id) } label: { Image(systemName: "trash") }.help(t("common.delete")).accessibilityLabel(t("common.delete"))
                }.padding(.vertical, 8).disabled(runtime.active)
            }.overlay { if store.configuration.proxies.isEmpty { ContentUnavailableView(t("profiles.empty_title"), systemImage: "server.rack", description: Text(t("profiles.empty_body"))) } }
        }.padding(18)
    }
    private var logsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(t("logs.title")).font(.title3.bold()); Spacer(); Text(t("logs.limit")).foregroundStyle(.secondary).font(.caption) }
            Text(t("logs.original")).font(.caption).foregroundStyle(.secondary)
            if let restoration = runtime.restoration { Text(language.render(restoration)).font(.callout).textSelection(.enabled) }
            ScrollView {
                if runtime.displayLogs(language: language.language).isEmpty {
                    Text(t("logs.empty")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                } else {
                    Text(verbatim: runtime.displayLogs(language: language.language).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).environment(\.layoutDirection, .leftToRight).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                }
            }.background(.background, in: RoundedRectangle(cornerRadius: 8))
        }.padding(18)
    }
    private var limitationsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(t("help.title")).font(.title2.bold())
                Text(t("help.steps"))
                Text(t("help.tcp"))
                Text(t("help.helpers"))
                Text(t("help.udp"))
                Text(t("help.dns"))
                Text(t("help.ipv6"))
                Text(t("help.lifecycle"))
                Text(t("help.license"))
                Link(t("help.project"), destination: URL(string: "https://github.com/MRongM/app-proxy")!)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject private var language: LanguageSettings
    private func t(_ key: String) -> String { language.text(key) }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    @State var profile: ProxyProfile
    @State private var password = ""
    @State private var replacePassword = false
    @State private var error: LocalizedMessage?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("nav.proxies")).font(.title2.bold())
            Form {
                TextField(t("profiles.name"), text: $profile.name)
                Picker(t("profiles.kind"), selection: $profile.kind) { ForEach(ProxyKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField(t("profiles.host"), text: $profile.host).environment(\.layoutDirection, .leftToRight)
                TextField(t("profiles.port"), value: $profile.port, format: .number.grouping(.never)).environment(\.layoutDirection, .leftToRight)
                TextField(t("profiles.username"), text: $profile.username)
                if profile.hasPassword { Toggle(t("profiles.replace_password"), isOn: $replacePassword) }
                if !profile.hasPassword || replacePassword { SecureField(t("profiles.password"), text: $password) }
            }.formStyle(.grouped)
            if let error { Text(language.render(error)).foregroundStyle(.red).font(.callout) }
            HStack {
                Text(t("profiles.http_warning")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("common.save")) {
                    do {
                        let keep = profile.hasPassword && !replacePassword
                        var candidate = profile; candidate.host = candidate.host.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !keep { candidate.hasPassword = !password.isEmpty }
                        try store.saveProfile(candidate, password: password, keepPassword: keep); dismiss()
                    } catch { self.error = .from(error) }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(minWidth: 570, idealWidth: 650)
    }
}
