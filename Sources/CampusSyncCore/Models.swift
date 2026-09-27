import Foundation

// Respuestas de la API de Web Services de Moodle. Casi todo es opcional porque
// Moodle omite campos según la versión y la configuración del sitio: un campo
// ausente no debe romper el sync entero.

public struct SiteInfo: Decodable, Sendable {
    public let sitename: String?
    public let username: String?
    public let fullname: String?
    public let userid: Int
    public let release: String?
}

public struct Course: Decodable, Sendable, Equatable {
    public let id: Int
    public let shortname: String?
    public let fullname: String?
    public let displayname: String?

    public init(id: Int, shortname: String? = nil, fullname: String? = nil, displayname: String? = nil) {
        self.id = id
        self.shortname = shortname
        self.fullname = fullname
        self.displayname = displayname
    }

    public var title: String {
        for candidate in [displayname, fullname, shortname] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return "Curso \(id)"
    }
}

public struct CourseSection: Decodable, Sendable {
    public let id: Int
    public let name: String?
    public let section: Int?
    private let modules: [CourseModule]?

    public var courseModules: [CourseModule] { modules ?? [] }
}

public struct CourseModule: Decodable, Sendable {
    public let id: Int
    public let name: String?
    public let modname: String
    public let url: String?
    public let uservisible: Bool?
    public let contents: [ModuleContent]?
}

public struct ModuleContent: Decodable, Sendable {
    public let type: String
    public let filename: String?
    public let filepath: String?
    public let filesize: Int?
    public let fileurl: String?
    public let timemodified: Int?
    public let mimetype: String?
}

/// Forma de los errores de Moodle. `server.php` usa `exception`/`errorcode`/`message`;
/// `login/token.php` usa `error`/`errorcode`.
struct MoodleErrorPayload: Decodable {
    let exception: String?
    let errorcode: String?
    let message: String?
    let error: String?

    var isError: Bool { exception != nil || errorcode != nil || error != nil }
}
