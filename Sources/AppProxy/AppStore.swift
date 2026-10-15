import AppKit
import AppProxyKit
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var configuration = AppConfiguration()
    @Published var error: String?
    @Published private(set) var loaded = false
    let secrets = KeychainSecrets()
    let persistence: ConfigurationStore

    init(directory: URL = AppPaths.support) {
        persistence = ConfigurationStore(directory: directory)
        if directory == AppPaths.support { _ = try? SessionDirectory.cleanupAbandoned() }
        do { configuration = try persistence.load(); loaded = true }
        catch { self.error = "读取配置失败，请修复 configuration.json 后重新打开应用。\n" + error.localizedDescription }
    }
    func change(_ update: (inout AppConfiguration) throws -> Void) {
        guard loaded else { return }
        do {
            var candidate = configuration; try update(&candidate)
            try persistence.save(candidate); configuration = candidate
        } catch { self.error = error.localizedDescription }
    }
    func saveProfile(_ profile: ProxyProfile, password: String, keepPassword: Bool) throws {
        guard loaded else { throw AppProxyError("原配置未成功读取，不能覆盖") }
        var candidate = configuration
        if let index = candidate.proxies.firstIndex(where: { $0.id == profile.id }) { candidate.proxies[index] = profile }
        else { candidate.proxies.append(profile) }
        try candidate.validate()
        let original = try secrets.read(profile.id)
        _ = try ConfigurationCompiler.compile(AppConfiguration(proxies: [profile]), passwords: profile.hasPassword ? [profile.id.uuidString: keepPassword ? (original ?? "") : password] : [:])
        do {
            if !keepPassword {
                if profile.hasPassword { try secrets.save(password, for: profile.id) }
                else { try secrets.delete(profile.id) }
            }
            try persistence.save(candidate); configuration = candidate
        } catch {
            if let original { try? secrets.save(original, for: profile.id) } else { try? secrets.delete(profile.id) }
            throw error
        }
    }
    func deleteProfile(_ id: UUID) {
        do {
            var candidate = configuration; try candidate.removeProxy(id: id)
            try persistence.save(candidate); configuration = candidate
            try secrets.delete(id)
        } catch { self.error = error.localizedDescription }
    }
    func selectApplication() {
        guard let proxy = configuration.proxies.first else { error = "请先添加代理配置"; return }
        let panel = NSOpenPanel(); panel.title = "选择需要代理的应用"; panel.prompt = "添加应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            do {
                let rules = try panel.urls.map { try AppSelection.rule(for: $0, proxyID: proxy.id) }
                change { $0.rules.append(contentsOf: rules) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func passwords() throws -> [String: String] {
        var result: [String: String] = [:]
        for p in configuration.proxies where p.hasPassword {
            guard let password = try secrets.read(p.id) else { throw AppProxyError("Keychain 中缺少密码：" + p.name) }
            result[p.id.uuidString] = password
        }
        return result
    }
}
