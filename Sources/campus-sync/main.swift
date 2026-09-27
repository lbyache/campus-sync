import CampusSyncCore
import Darwin
import Foundation

let usage = """
    campus-sync — espejo local del campus Moodle

    Uso:
      campus-sync login [--token]   Guarda la sesión en el Llavero (la contraseña no se guarda).
      campus-sync cursos            Lista tus materias con su id (para alias y exclusiones).
      campus-sync status            ¿Tengo todo? Compara campus y carpeta local. No descarga nada.
      campus-sync sync              Baja lo nuevo y lo modificado, escribe NOVEDADES.md y avisa.
      campus-sync logout            Borra el token del Llavero.

    Configuración: ~/.config/campus-sync/config.json
    """

let arguments = Array(CommandLine.arguments.dropFirst())
var redactor = Redactor()

/// Sin terminal (launchd) nadie ve la salida en el momento: se agrega la hora para el log
/// y los errores se avisan también con una notificación.
let interactive = isatty(STDIN_FILENO) == 1

@MainActor func printError(_ message: String) {
    let prefix = interactive ? "" : "[\(Date().formatted(.iso8601))] "
    FileHandle.standardError.write(Data((prefix + redactor.redact(message) + "\n").utf8))
}

@MainActor func fail(_ error: Error) -> Never {
    let description = redactor.redact(String(describing: error))
    printError("campus-sync: \(description)")
    if !interactive {
        Reporter.notify(title: "campus-sync: falló el sync", message: description)
    }
    exit(1)
}

@MainActor func prompt(_ label: String, default defaultValue: String? = nil) -> String {
    let suffix = defaultValue.map { " [\($0)]" } ?? ""
    print("\(label)\(suffix): ", terminator: "")
    // Entrada cerrada (EOF): sin esto, los bucles que repreguntan no terminarían nunca.
    guard let line = readLine() else {
        fail(CampusSyncError.config("la entrada se cerró; el login se corre a mano en una terminal"))
    }
    let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return answer.isEmpty ? (defaultValue ?? "") : answer
}

/// Lee sin eco en la terminal. Exige una TTY: no acepta la contraseña por un pipe.
@MainActor func readSecret(_ label: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
    guard let pointer = readpassphrase(label, &buffer, buffer.count, Int32(RPP_REQUIRE_TTY)) else {
        return nil
    }
    let value = String(cString: pointer)
    return value.isEmpty ? nil : value
}

@MainActor func loadConfig() throws -> Config {
    guard let config = try Config.load() else { throw CampusSyncError.notLoggedIn }
    return config
}

@MainActor func makeClient(_ config: Config) throws -> MoodleClient {
    let campus = try config.campus()
    let token = try Keychain.readToken(account: campus.host() ?? config.campusURL)
    redactor = Redactor(secrets: [token])
    return try MoodleClient(baseURL: campus, token: token)
}

// MARK: - Comandos

@MainActor func login() async throws {
    let existing = try Config.load()
    var campus: URL?
    while campus == nil {
        let answer = prompt("URL del campus (https://…)", default: existing?.campusURL)
        do {
            campus = try Config(campusURL: answer, destination: "/").campus()
        } catch {
            printError("\(error)")
        }
    }
    guard let campus else { throw CampusSyncError.config("URL inválida") }
    // Una configuración vieja con un destino inválido no se ofrece como valor por defecto.
    var previous: String?
    if let saved = existing?.destination, (try? Config.validateDestination(saved)) != nil {
        previous = saved
    }
    var destination = ""
    while destination.isEmpty {
        let answer = prompt(
            "Carpeta destino, ruta de la Mac (Drive: ~/Library/CloudStorage/GoogleDrive-<cuenta>/Mi unidad/…)",
            default: previous ?? "~/Campus"
        )
        do {
            let url = try Config.validateDestination(answer)
            if !FileManager.default.fileExists(atPath: url.path) {
                // Una carpeta inexistente suele ser un error de tipeo: se confirma antes de crearla.
                let confirm = prompt("La carpeta \(url.path) no existe. ¿La creo? (s/N)")
                guard confirm.lowercased() == "s" else { continue }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                print("Creé la carpeta \(url.path).")
            }
            destination = answer
        } catch {
            printError("\(error)")
        }
    }

    let token: String
    if arguments.contains("--token") {
        print("Token de Preferencias › Claves de seguridad del campus (servicio \"Moodle mobile web service\").")
        guard let manual = readSecret("Token: ") else {
            throw CampusSyncError.config("token vacío o sin terminal interactiva (el login se corre a mano en Terminal)")
        }
        token = manual
    } else {
        let username = prompt("Usuario del campus")
        guard !username.isEmpty, let password = readSecret("Contraseña (no se muestra ni se guarda): ") else {
            throw CampusSyncError.config(
                "usuario o contraseña vacíos, o sin terminal interactiva (el login se corre a mano en Terminal)")
        }
        token = try await MoodleClient.requestToken(baseURL: campus, username: username, password: password)
    }
    redactor = Redactor(secrets: [token])

    let client = try MoodleClient(baseURL: campus, token: token)
    let site = try await client.siteInfo()

    var config = existing ?? Config(campusURL: campus.absoluteString, destination: destination)
    config.campusURL = campus.absoluteString
    config.destination = destination
    try Keychain.saveToken(token, account: campus.host() ?? campus.absoluteString)
    try config.save()

    print(
        """

        Listo: sesión de \(site.fullname ?? site.username ?? "?") en \(site.sitename ?? "el campus") \
        (Moodle \(site.release ?? "?")).
        Token guardado en el Llavero. Configuración en \(Config.defaultURL.path).

        Siguiente paso: `campus-sync cursos` para ver tus materias, y `campus-sync status`.
        """)
}

@MainActor func courses() async throws {
    let config = try loadConfig()
    let client = try makeClient(config)
    let site = try await client.siteInfo()
    let list = try await client.courses(userID: site.userid)
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    for course in list {
        let mark = config.includes(course.id) ? "✔" : "·"
        let alias = config.aliases?[String(course.id)].map { " → \($0)" } ?? ""
        print("\(mark) \(course.id)\t\(course.title)\(alias)")
    }
    print("\n✔ = se sincroniza. Alias y exclusiones: \(Config.defaultURL.path)")
}

@MainActor func status() async throws {
    let config = try loadConfig()
    let engine = SyncEngine(client: try makeClient(config), config: config, log: Logger(redactor: redactor))
    let report = try await engine.run(apply: false)
    print(Reporter.statusText(report))
}

@MainActor func sync() async throws -> Int32 {
    let config = try loadConfig()
    let engine = SyncEngine(client: try makeClient(config), config: config, log: Logger(redactor: redactor))
    let report = try await engine.run(apply: true)

    if let block = Reporter.novedadesBlock(report) {
        let destination = try config.existingDestinationDirectory()
        let novedades = try SafePath.resolve("NOVEDADES.md", under: destination)
        try Reporter.prependNovedades(block, at: novedades)
        Reporter.notify(title: "Campus: novedades", message: Reporter.summary(report))
    }
    print(report.hasChanges ? Reporter.summary(report) : "Sin novedades en el campus.")
    return report.failureCount > 0 ? 2 : 0
}

@MainActor func logout() throws {
    let config = try loadConfig()
    let campus = try config.campus()
    try Keychain.deleteToken(account: campus.host() ?? config.campusURL)
    print("Token borrado del Llavero.")
}

// MARK: - Entrada

do {
    switch arguments.first ?? "help" {
    case "login": try await login()
    case "cursos", "courses": try await courses()
    case "status": try await status()
    case "sync": exit(try await sync())
    case "logout": try logout()
    case "help", "-h", "--help": print(usage)
    default:
        printError(usage)
        exit(64)
    }
} catch {
    fail(error)
}
