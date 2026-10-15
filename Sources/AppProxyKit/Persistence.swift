import Foundation

public struct ConfigurationStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("configuration.json") }
    public init(directory: URL = AppPaths.support) { self.directory = directory }
    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppConfiguration() }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 1_048_576 else { throw AppProxyError(localized: "error.config.size") }
        let c = try JSONDecoder().decode(AppConfiguration.self, from: data)
        try c.validate(); return c
    }
    public func save(_ configuration: AppConfiguration) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFiles.write(encoder.encode(configuration), to: fileURL)
    }
}

public enum AppPaths {
    public static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/App Proxy", isDirectory: true) }
    public static var sessions: URL { support.appendingPathComponent("Sessions", isDirectory: true) }
}

public enum SecureFiles {
    public static func write(_ data: Data, to url: URL) throws {
        // Atomic replacement prevents readers from seeing partial JSON and preserves no old secret file.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
