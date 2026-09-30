import Foundation

// Piezas del asistente `campus-sync setup` que no necesitan una terminal: se testean por separado.

// MARK: - URL del campus

public enum CampusURL {
    /// Lo que la gente pega suele ser una página del campus (`…/login/index.php`, `…/my/`,
    /// `…/course/view.php?id=…`) o no tener `https://`. Se reduce a la raíz de Moodle.
    public static func normalize(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CampusSyncError.config("la URL del campus está vacía.") }
        if text.lowercased().hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        } else if !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), components.host?.contains(".") == true else {
            throw CampusSyncError.config("\"\(raw)\" no parece la dirección de un campus.")
        }
        components.query = nil
        components.fragment = nil
        var path = components.path
        let pages = [
            "/login/", "/my/", "/my", "/course/", "/mod/", "/user/", "/admin/", "/auth/", "/calendar/",
            "/grade/", "/message/", "/pluginfile.php", "/webservice/", "/index.php",
        ]
        if let cut = pages.compactMap({ path.range(of: $0)?.lowerBound }).min() {
            path = String(path[..<cut])
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url else { throw CampusSyncError.config("URL inválida: \(raw)") }
        return url
    }
}

// MARK: - Configuración pública del sitio (sin credenciales)

public struct PublicSiteConfig: Decodable, Sendable, Equatable {
    public let wwwroot: String?
    public let sitename: String?
    public let enablewebservices: Int?
    public let enablemobilewebservice: Int?
    /// 1 = login dentro de la app (usuario y contraseña); 2 y 3 = navegador (SSO).
    public let typeoflogin: Int?

    public var mobileAccessEnabled: Bool { enablewebservices == 1 && enablemobilewebservice == 1 }
    public var usesPasswordLogin: Bool { typeoflogin == nil || typeoflogin == 1 }

    struct Envelope: Decodable {
        let error: Bool?
        let data: PublicSiteConfig?
    }

    public static func decode(_ data: Data) throws -> PublicSiteConfig {
        guard let envelope = try? JSONDecoder().decode([Envelope].self, from: data).first,
            envelope.error != true, let config = envelope.data
        else {
            throw CampusSyncError.unexpectedResponse("tool_mobile_get_public_config")
        }
        return config
    }
}

extension MoodleClient {
    /// La misma consulta que hace la app oficial antes de pedir usuario: dice si el campus acepta
    /// la app móvil y cómo es el login. No usa credenciales.
    public static func publicConfig(baseURL: URL, send: HTTPTransport = MoodleClient.urlSessionSend) async throws
        -> PublicSiteConfig
    {
        try requireHTTPS(baseURL)
        var components = URLComponents(
            url: baseURL.appending(path: "lib/ajax/service-nologin.php"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "info", value: "tool_mobile_get_public_config")]
        guard let url = components?.url else { throw CampusSyncError.unexpectedResponse("publicConfig") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"[{"index":0,"methodname":"tool_mobile_get_public_config","args":{}}]"#.utf8)
        let (data, response) = try await send(request)
        try checkHTTP(response)
        return try PublicSiteConfig.decode(data)
    }
}

// MARK: - Nombres cortos de cursos

public enum CourseNaming {
    /// "ASIG00194 - Algoritmos y Estructuras de Datos-2/2026" → "Algoritmos y Estructuras de Datos".
    /// Quita un código inicial y el período final; si no queda nada, devuelve el título original.
    public static func suggestedAlias(for title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Código de asignatura al principio: letras + dígitos, seguido de " - ", "_" o ":".
        name = name.replacing(#/^[A-Za-z]{2,}\d{2,}\s*[-_:]\s*/#, with: "")
        // Período al final: "-2/2026", "_2/2026", " - 2C 2026", " 2026", "(2026)".
        name = name.replacing(#/[\s_\-]*\(?\s*(\d\s*[cC]?\s*[/\-]?\s*)?(19|20)\d{2}\s*\)?$/#, with: "")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -_:").union(.whitespaces))
        return name.isEmpty ? title : name
    }
}

// MARK: - Selección de ítems numerados

public enum Selection {
    /// "2, 5-7" → {2, 5, 6, 7}. Vacío → conjunto vacío. Los números son 1..count.
    public static func parse(_ text: String, count: Int) throws -> Set<Int> {
        var result = Set<Int>()
        for part in text.split(whereSeparator: { $0 == "," || $0 == " " }) where !part.isEmpty {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count), let low = Int(bounds[0]),
                let high = bounds.count == 2 ? Int(bounds[1]) : low, low <= high
            else {
                throw CampusSyncError.config("no entendí \"\(part)\"; usá números y rangos, p. ej. 2, 5-7.")
            }
            guard low >= 1, high <= count else {
                throw CampusSyncError.config("\(part) está fuera de la lista (1 a \(count)).")
            }
            result.formUnion(low...high)
        }
        return result
    }
}

// MARK: - Carpetas en la nube

public struct FolderCandidate: Sendable, Equatable {
    public let label: String
    public let url: URL
}

public enum CloudFolders {
    /// Carpetas sincronizadas conocidas, para elegir por número en lugar de tipear una ruta.
    public static func candidates(home: URL, fileManager: FileManager = .default) -> [FolderCandidate] {
        var result: [FolderCandidate] = []
        let cloudStorage = home.appending(path: "Library/CloudStorage")
        let entries = ((try? fileManager.contentsOfDirectory(atPath: cloudStorage.path)) ?? []).sorted()
        for entry in entries {
            let base = cloudStorage.appending(path: entry)
            if entry.hasPrefix("GoogleDrive-") {
                let account = String(entry.dropFirst("GoogleDrive-".count))
                for myDrive in ["Mi unidad", "My Drive", "Meine Ablage", "Mon Drive", "Meu Drive"]
                where fileManager.fileExists(atPath: base.appending(path: myDrive).path) {
                    result.append(FolderCandidate(label: "Google Drive (\(account))", url: base.appending(path: myDrive)))
                }
            } else if entry.hasPrefix("OneDrive") {
                result.append(FolderCandidate(label: "OneDrive (\(entry))", url: base))
            } else if entry.hasPrefix("Dropbox") {
                result.append(FolderCandidate(label: "Dropbox", url: base))
            }
        }
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if fileManager.fileExists(atPath: iCloud.path) {
            result.append(FolderCandidate(label: "iCloud Drive", url: iCloud))
        }
        result.append(FolderCandidate(label: "Documentos (solo en esta Mac)", url: home.appending(path: "Documents")))
        return result
    }

    /// Ruta con `~` para guardar en la configuración, si está dentro de la carpeta personal.
    public static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~/" + path.dropFirst(homePath.count + 1) }
        return path
    }
}

// MARK: - Tarea programada (launchd)

public enum Schedule: Sendable, Equatable {
    case weekly(weekday: Int, hour: Int, minute: Int)  // weekday: 0 = domingo
    case daily(hour: Int, minute: Int)
    case manual

    public static let defaultWeekly = Schedule.weekly(weekday: 0, hour: 10, minute: 0)
    public static let defaultDaily = Schedule.daily(hour: 8, minute: 0)

    public var description: String {
        let days = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
        switch self {
        case .weekly(let weekday, let hour, let minute):
            return "una vez por semana, \(days[weekday % 7]) \(String(format: "%02d:%02d", hour, minute))"
        case .daily(let hour, let minute):
            return "todos los días a las \(String(format: "%02d:%02d", hour, minute))"
        case .manual:
            return "solo cuando corras `campus-sync sync`"
        }
    }
}

public enum LaunchAgent {
    public static let label = "local.campus-sync"

    public static func plistURL(home: URL) -> URL {
        home.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// PURO: plist serializado (nunca por interpolación de texto, así una ruta rara no rompe el XML).
    public static func plist(executable: String, schedule: Schedule, logPath: String) throws -> Data {
        var interval: [String: Int] = [:]
        switch schedule {
        case .weekly(let weekday, let hour, let minute):
            interval = ["Weekday": weekday, "Hour": hour, "Minute": minute]
        case .daily(let hour, let minute):
            interval = ["Hour": hour, "Minute": minute]
        case .manual:
            throw CampusSyncError.config("una tarea manual no se programa.")
        }
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "sync"],
            "StartCalendarInterval": interval,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Background",
            "LowPriorityIO": true,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// Instala (o quita, si es manual) la tarea en launchd para la sesión actual.
    public static func apply(_ schedule: Schedule, executable: String, home: URL) throws {
        let plistURL = plistURL(home: home)
        let domain = "gui/\(getuid())"
        _ = try? run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        guard schedule != .manual else {
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        guard executable.hasPrefix("/") else {
            throw CampusSyncError.config("la ruta del programa tiene que ser absoluta: \(executable)")
        }
        let logs = home.appending(path: "Library/Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist(executable: executable, schedule: schedule, logPath: logs.appending(path: "campus-sync.log").path)
            .write(to: plistURL, options: .atomic)
        let status = try run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        guard status == 0 else {
            throw CampusSyncError.config("launchctl no pudo programar la tarea (código \(status)).")
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
