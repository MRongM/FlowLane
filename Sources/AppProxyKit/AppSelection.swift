import Foundation

public enum AppSelection {
    public static func rule(for url: URL, proxyID: UUID? = nil) throws -> ApplicationRule {
        let app = url.resolvingSymlinksInPath().standardizedFileURL
        guard app.pathExtension == "app", let bundle = Bundle(url: app), let executable = bundle.executableURL?.resolvingSymlinksInPath(),
              executable.path.hasPrefix(app.path + "/"), FileManager.default.isExecutableFile(atPath: executable.path) else { throw AppProxyError(localized: "error.application.bundle") }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? app.deletingPathExtension().lastPathComponent
        return ApplicationRule(name: name, appPath: app.path, executablePath: executable.path, proxyID: proxyID, enabled: proxyID != nil)
    }
}
