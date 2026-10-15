import AppKit
import AppProxyKit
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var configuration = AppConfiguration()
    @Published var error: LocalizedMessage?
    @Published private(set) var loaded = false
    let secrets = KeychainSecrets()
    let persistence: ConfigurationStore

    init(directory: URL = AppPaths.support) {
        persistence = ConfigurationStore(directory: directory)
        if directory == AppPaths.support { _ = try? SessionDirectory.cleanupAbandoned() }
        do { configuration = try persistence.load(); loaded = true }
        catch { self.error = LocalizedMessage("error.config_load", values: [.from(error)], table: .interface) }
    }
    func change(_ update: (inout AppConfiguration) throws -> Void) {
        guard loaded else { return }
        do {
            var candidate = configuration; try update(&candidate)
            try persistence.save(candidate); configuration = candidate
        } catch { self.error = .from(error) }
    }
    func saveProfile(_ profile: ProxyProfile, password: String, keepPassword: Bool) throws {
        guard loaded else { throw AppProxyError(content: LocalizedMessage("error.config_unavailable", table: .interface)) }
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
        guard loaded else { return }
        do {
            var candidate = configuration; try candidate.removeProxy(id: id)
            try persistence.save(candidate); configuration = candidate
            try secrets.delete(id)
        } catch { self.error = .from(error) }
    }
    func selectApplication(language: AppLanguage = .en) {
        guard loaded else { return }
        let panel = NSOpenPanel()
        panel.title = Localization.text("apps.picker_title", language: language)
        panel.prompt = Localization.text("apps.add", language: language)
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]; panel.allowsOtherFileTypes = false
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false; panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addApplications(panel.urls) }
    }
    func addApplications(_ urls: [URL]) {
        guard loaded else { return }
        do {
            let rules = try urls.map { try AppSelection.rule(for: $0, proxyID: configuration.proxies.first?.id) }
            change { $0.rules.append(contentsOf: rules) }
        } catch { self.error = .from(error) }
    }
    func assignProxy(_ proxyID: UUID?, to ruleID: UUID) {
        change { candidate in
            guard let index = candidate.rules.firstIndex(where: { $0.id == ruleID }) else { throw AppProxyError(content: LocalizedMessage("error.rule_missing", table: .interface)) }
            if let proxyID, !candidate.proxies.contains(where: { $0.id == proxyID }) { throw AppProxyError(content: LocalizedMessage("error.proxy_missing", table: .interface)) }
            let wasUnassigned = candidate.rules[index].proxyID == nil
            candidate.rules[index].proxyID = proxyID
            if proxyID == nil { candidate.rules[index].enabled = false }
            else if wasUnassigned { candidate.rules[index].enabled = true }
        }
    }
    func passwords() throws -> [String: String] {
        var result: [String: String] = [:]
        for p in configuration.proxies where p.hasPassword {
            guard let password = try secrets.read(p.id) else { throw AppProxyError(content: LocalizedMessage("error.password_missing", arguments: [p.name], table: .interface)) }
            result[p.id.uuidString] = password
        }
        return result
    }
}
