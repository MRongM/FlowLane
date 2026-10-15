import AppKit
import AppProxyKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var runtime: RuntimeController
    @State private var tab = 0
    @State private var editor: ProxyProfile?
    @State private var showNewProxy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let logo = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/FlowLane.png")) {
                    Image(nsImage: logo).resizable().frame(width: 48, height: 48)
                } else {
                    Image(systemName: "arrow.triangle.branch").font(.largeTitle).foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("流径 FlowLane").font(.title2.bold())
                    Text("为每个应用选择连接方式").foregroundStyle(.secondary)
                }
                Spacer()
                Label(runtime.state.phase.title, systemImage: runtime.state.phase == .running ? "circle.fill" : "circle")
                    .foregroundStyle(runtime.state.phase == .running ? .green : runtime.state.phase == .failed ? .red : .secondary)
                if runtime.active {
                    Button("停止网络接管", role: .destructive) { runtime.stop() }.disabled(runtime.state.phase == .stopping)
                } else {
                    Button("启动网络接管") { runtime.start(store: store) }.buttonStyle(.borderedProminent)
                        .disabled(!store.loaded || !store.configuration.rules.contains(where: \.enabled))
                }
            }.padding(22)
            Divider()
            HStack {
                Text(runtime.state.message).foregroundStyle(runtime.state.phase == .failed ? .red : .secondary).textSelection(.enabled)
                Spacer()
                Text("sing-box 1.14.3 · TCP").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.vertical, 12)
            TabView(selection: $tab) {
                rulesView.tabItem { Label("应用规则", systemImage: "app.badge.checkmark") }.tag(0)
                profilesView.tabItem { Label("代理配置", systemImage: "server.rack") }.tag(1)
                logsView.tabItem { Label("连接与运行日志", systemImage: "text.alignleft") }.tag(2)
                limitationsView.tabItem { Label("使用说明", systemImage: "info.circle") }.tag(3)
            }.padding([.horizontal, .bottom], 18)
        }
        .sheet(isPresented: $showNewProxy) { ProfileEditor(store: store, profile: ProxyProfile(name: "", kind: .socks5, host: "", port: 1080)) }
        .sheet(item: $editor) { ProfileEditor(store: store, profile: $0) }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var rulesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("应用规则").font(.title3.bold())
                    Text("从上到下匹配；未匹配或未知进程默认直连。").foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.selectApplication() } label: { Label("添加应用", systemImage: "plus") }
                    .disabled(runtime.active || !store.loaded)
            }
            if store.configuration.rules.isEmpty {
                ContentUnavailableView("添加需要代理的应用", systemImage: "app.dashed", description: Text("可先选择 .app，稍后分配代理。未分配代理的规则保持停用。"))
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
            Label("启动将请求管理员授权；TUN 接收流量后再分流。", systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
        }.padding(18)
    }
    private func ruleRow(_ rule: ApplicationRule, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
            Image(nsImage: NSWorkspace.shared.icon(forFile: rule.appPath)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 7) {
                Text(rule.name).font(.headline)
                Text(rule.appPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("主进程：" + rule.executablePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(rule.executablePath)
                if rule.proxyID == nil { Text("未分配代理，暂不启用").font(.caption).foregroundStyle(.secondary) }
                Toggle("包含应用包内的 Helper / XPC", isOn: ruleBinding(rule, \.includeHelpers)).font(.caption)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Picker("代理", selection: Binding<UUID?>(get: {
                    store.configuration.rules.first(where: { $0.id == rule.id })?.proxyID
                }, set: { store.assignProxy($0, to: rule.id) })) {
                    Text("未分配代理").tag(Optional<UUID>.none)
                    ForEach(store.configuration.proxies) { p in Text(p.name).tag(Optional(p.id)) }
                }.frame(width: 220)
                HStack {
                    Toggle("启用", isOn: ruleBinding(rule, \.enabled)).toggleStyle(.switch).controlSize(.small)
                        .disabled(rule.proxyID == nil)
                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == store.configuration.rules.count - 1)
                    Button(role: .destructive) { store.change { $0.rules.removeAll { $0.id == rule.id } } } label: { Image(systemName: "trash") }
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
                Text("代理配置").font(.title3.bold()); Spacer()
                Button { showNewProxy = true } label: { Label("添加代理", systemImage: "plus") }.disabled(runtime.active || !store.loaded)
            }
            Text("使用你已有的代理服务。密码保存在 macOS Keychain。").foregroundStyle(.secondary)
            List(store.configuration.proxies) { p in
                HStack {
                    Image(systemName: "server.rack").foregroundStyle(.blue).font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(p.name).font(.headline)
                        Text("\(p.kind.title) · \(p.host):\(p.port)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p.hasPassword { Image(systemName: "key.fill").foregroundStyle(.secondary).help("密码已保存在 Keychain") }
                    Button("编辑") { editor = p }
                    Button(role: .destructive) { store.deleteProfile(p.id) } label: { Image(systemName: "trash") }
                }.padding(.vertical, 8).disabled(runtime.active)
            }.overlay { if store.configuration.proxies.isEmpty { ContentUnavailableView("尚无代理配置", systemImage: "server.rack", description: Text("支持 SOCKS5 和 HTTP CONNECT，认证信息可选。")) } }
        }.padding(18)
    }
    private var logsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("连接与运行日志").font(.title3.bold()); Spacer(); Text("最近 150 条 · 不解密 TLS").foregroundStyle(.secondary).font(.caption) }
            if let restoration = runtime.restoration { Text(restoration).font(.callout).textSelection(.enabled) }
            ScrollView {
                Text(runtime.logs.isEmpty ? "尚无运行日志。启动后将显示内核记录的连接目标、进程归属（可用时）和分流结果。无归属字段的连接视为未知，默认直连。" : runtime.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.background(.background, in: RoundedRectangle(cornerRadius: 8))
        }.padding(18)
    }
    private var limitationsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("连接范围与使用方式").font(.title2.bold())
                Text("1. 添加已有代理。2. 选择应用并分配代理。3. 点击“启动网络接管”并在 macOS 弹窗授权。规则修改需要先停止。停止会断开经过内核的现有连接。")
                Text("TCP：支持 SOCKS5 和 HTTP CONNECT；已识别且匹配的连接在代理故障时返回错误。未知归属默认直连，本工具不提供防泄漏保证。")
                Text("Helper：默认匹配 .app 包内进程。包外的 WebKit 网络服务、系统共享服务和其他代理工具不能自动归为某个应用。应用升级或移动后应重新选择。")
                Text("UDP / QUIC：匹配应用的 UDP 被拒绝，可促使支持的客户端回退 TCP。未匹配 UDP 直连；共享/未知进程 UDP 同样可能直连。")
                Text("DNS：系统 DNS 设置不变，端口 53 直连；不提供 DNS 隐私或按应用 DNS。应用自己的 DoH/DoT TCP 仍适用进程规则。")
                Text("IPv6：配置与 IPv4 一并接入 TUN；管理员授权后的真实接管和恢复需按验收文档核实。Loopback、本地链路、绑定特定接口或其他 VPN 的更高优先级路由可能绕过 TUN。")
                Text("网络状态：内核出站绑定检测到的原接口；已验证的本地上游进程及其整个应用包优先直连以避免回环，覆盖应用规则，例外列入日志。无法验证上游监听进程时拒绝启动，进程重启后需重启会话。停止后比较路由与 DNS，只清理本会话，不覆盖其他网络软件的设置。")
                Text("此构建采用本地 ad-hoc 签名，无需 Apple 开发者账号，未公证。sing-box 1.14.3（GPL-3.0-or-later）随应用附带许可与源码链接。")
                Link("项目说明与验收记录", destination: URL(string: "https://github.com/MRongM/app-proxy")!)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }
    }
}

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    @State var profile: ProxyProfile
    @State private var password = ""
    @State private var replacePassword = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("代理配置").font(.title2.bold())
            Form {
                TextField("名称", text: $profile.name)
                Picker("类型", selection: $profile.kind) { ForEach(ProxyKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField("主机（不含协议）", text: $profile.host)
                TextField("端口", value: $profile.port, format: .number.grouping(.never))
                TextField("用户名（可选）", text: $profile.username)
                if profile.hasPassword { Toggle("替换或删除已有密码", isOn: $replacePassword) }
                if !profile.hasPassword || replacePassword { SecureField("密码（可选）", text: $password) }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Text("HTTP CONNECT 为明文上游协议；请使用可信网络。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        let keep = profile.hasPassword && !replacePassword
                        var candidate = profile; candidate.host = candidate.host.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !keep { candidate.hasPassword = !password.isEmpty }
                        try store.saveProfile(candidate, password: password, keepPassword: keep); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width: 570)
    }
}
