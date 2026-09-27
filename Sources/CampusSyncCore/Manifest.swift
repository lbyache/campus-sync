import Foundation

/// Lo que se sabe de cada archivo ya descargado de una materia.
public struct Manifest: Codable, Sendable, Equatable {
    public var courseID: Int
    public var courseTitle: String
    public var entries: [String: ManifestEntry]

    public init(courseID: Int, courseTitle: String, entries: [String: ManifestEntry] = [:]) {
        self.courseID = courseID
        self.courseTitle = courseTitle
        self.entries = entries
    }
}

public struct ManifestEntry: Codable, Sendable, Equatable {
    public var key: String
    public var sectionName: String
    public var moduleName: String
    public var filename: String
    public var fileurl: String
    public var filesize: Int
    public var timemodified: Int
    public var relativePath: String
    public var sha256: String?
    public var downloadedAt: Date?
    /// Fecha en que el archivo dejó de aparecer en el campus. El archivo local no se borra.
    public var retiredAt: Date?

    public init(remote: RemoteFile, sha256: String?, downloadedAt: Date?) {
        key = remote.key
        sectionName = remote.sectionName
        moduleName = remote.moduleName
        filename = remote.filename
        fileurl = remote.fileurl
        filesize = remote.filesize
        timemodified = remote.timemodified
        relativePath = remote.relativePath
        self.sha256 = sha256
        self.downloadedAt = downloadedAt
        retiredAt = nil
    }
}

/// Manifiestos en `~/Library/Application Support/campus-sync/manifests/<curso>.json`.
/// Quedan fuera de la carpeta de Drive para no ensuciar el espejo.
public struct ManifestStore: Sendable {
    public let directory: URL

    public init(directory: URL = ManifestStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "campus-sync/manifests", directoryHint: .isDirectory)
    }

    public func load(courseID: Int) throws -> Manifest? {
        let url = fileURL(courseID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: url))
    }

    /// Todos los manifiestos guardados, ordenados por id de curso.
    public func all() throws -> [Manifest] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .compactMap { Int(($0 as NSString).deletingPathExtension) }
            .sorted()
            .compactMap { try load(courseID: $0) }
    }

    public func save(_ manifest: Manifest) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: fileURL(manifest.courseID), options: .atomic)
    }

    private func fileURL(_ courseID: Int) -> URL {
        directory.appending(path: "\(courseID).json")
    }
}
