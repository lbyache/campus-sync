import Foundation

/// `~/.config/campus-sync/config.json`. No contiene secretos: el token vive en el Llavero.
public struct Config: Codable, Sendable, Equatable {
    public var campusURL: String
    /// Carpeta espejo, idealmente dentro de Google Drive para verla en el iPhone.
    public var destination: String
    /// Si está presente y no vacía, solo se sincronizan estos cursos.
    public var includeCourses: [Int]?
    public var excludeCourses: [Int]?
    /// id de curso → nombre corto de la carpeta (p. ej. "1234": "Análisis II").
    public var aliases: [String: String]?
    public var maxFileSizeMB: Int?
    public var delayMilliseconds: Int?

    public init(campusURL: String, destination: String) {
        self.campusURL = campusURL
        self.destination = destination
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/campus-sync/config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> Config? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw CampusSyncError.config("no pude leer \(url.path): \(error.localizedDescription)")
        }
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func campus() throws -> URL {
        guard let url = URL(string: campusURL) else {
            throw CampusSyncError.config("campusURL inválida: \(campusURL)")
        }
        try MoodleClient.requireHTTPS(url)
        return url
    }

    /// Carpeta destino validada. Una ruta relativa se resolvería contra el directorio
    /// actual, que para launchd es `/`: por eso se exige absoluta (o con `~`).
    public func destinationDirectory() throws -> URL {
        try Self.validateDestination(destination)
    }

    /// `home` se inyecta en tests para no depender de la carpeta personal real.
    public static func validateDestination(
        _ raw: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            throw CampusSyncError.config(
                "la carpeta destino tiene que ser una ruta de la Mac, no un link web (\(trimmed.prefix(40))…). "
                    + "Las carpetas de Google Drive están en ~/Library/CloudStorage/GoogleDrive-<cuenta>/Mi unidad/")
        }
        let expanded: String
        if trimmed == "~" {
            expanded = home.path
        } else if trimmed.hasPrefix("~/") {
            expanded = home.appending(path: String(trimmed.dropFirst(2))).path
        } else {
            expanded = trimmed
        }
        guard expanded.hasPrefix("/") else {
            throw CampusSyncError.config("la carpeta destino tiene que empezar con / o con ~/ (recibí \"\(trimmed)\").")
        }
        return URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL
    }

    /// La carpeta destino tiene que existir antes de sincronizar. Si falta (por ejemplo, Google
    /// Drive no está abierto), se frena en vez de crear una copia nueva en otro lado.
    public func existingDestinationDirectory() throws -> URL {
        let url = try destinationDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CampusSyncError.config(
                "la carpeta destino no existe: \(url.path). ¿Está abierto Google Drive para escritorio? "
                    + "Si la cambiaste de lugar, corré `campus-sync login` para actualizarla.")
        }
        return url
    }

    public var maxFileBytes: Int { (maxFileSizeMB ?? 500) * 1024 * 1024 }
    public var delay: Duration { .milliseconds(delayMilliseconds ?? 400) }

    public func includes(_ courseID: Int) -> Bool {
        if let include = includeCourses, !include.isEmpty, !include.contains(courseID) { return false }
        return !(excludeCourses ?? []).contains(courseID)
    }

    public func folderName(for course: Course) -> String {
        aliases?[String(course.id)] ?? course.title
    }
}
