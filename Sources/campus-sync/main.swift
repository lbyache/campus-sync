import CampusSyncCore
import Darwin
import Foundation

let usage = """
    campus-sync — espejo local del campus Moodle

    Primera vez: campus-sync setup   (configuración guiada, 5 preguntas)

    Uso:
      campus-sync setup             Configuración guiada: campus, sesión, carpeta, cursos y frecuencia.
      campus-sync login [--token]   Guarda la sesión en el Llavero (la contraseña no se guarda).
      campus-sync cursos            Lista tus materias con su id (para alias y exclusiones).
      campus-sync status            ¿Tengo todo? Compara campus y carpeta local. No descarga nada.
      campus-sync sync              Baja lo nuevo y lo modificado, escribe NOVEDADES.md y avisa.
      campus-sync logout            Borra el token del Llavero.
      campus-sync programar [--semanal | --diario | --manual]
                                    Cada cuánto revisar novedades solo (por defecto, domingo 10:00).
      campus-sync reubicar [--destino RUTA] [--subcarpeta NOMBRE | --sin-subcarpeta] [--si]
                                    Mueve lo ya bajado a otra carpeta o estructura sin volver a bajarlo.
                                    Ej.: --subcarpeta Campus deja cada curso en <Materia>/Campus/.

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

    let token = try await obtainToken(campus: campus, passwordLogin: true)
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

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

@MainActor func relocate() throws {
    let config = try loadConfig()
    let oldRoot = try config.existingDestinationDirectory()
    let oldSubfolder = config.courseSubfolder
    let newDestination = value(after: "--destino") ?? config.destination
    let newSubfolder = arguments.contains("--sin-subcarpeta") ? nil : (value(after: "--subcarpeta") ?? oldSubfolder)

    var newConfig = config
    newConfig.destination = newDestination
    newConfig.courseSubfolder = newSubfolder
    let newRoot = try newConfig.existingDestinationDirectory()

    let store = ManifestStore()
    let manifests = try store.all()
    let plan = try Relocator.plan(
        manifests: manifests, from: oldRoot, to: newRoot, oldSubfolder: oldSubfolder, newSubfolder: newSubfolder)

    print("De: \(oldRoot.path)\(oldSubfolder.map { " (subcarpeta \($0))" } ?? "")")
    print("A:  \(newRoot.path)\(newSubfolder.map { " (subcarpeta \($0))" } ?? "")")
    print("Archivos a mover: \(plan.moves.count)")
    for move in plan.moves.prefix(5) { print("  \(move.from)\n    → \(move.to)") }
    if plan.moves.count > 5 { print("  … y \(plan.moves.count - 5) más") }
    if !plan.missing.isEmpty { print("No están en disco (se bajan en el próximo sync): \(plan.missing.count)") }
    if !plan.conflicts.isEmpty {
        print("Ya existen en el destino, no se mueve nada:")
        for path in plan.conflicts.prefix(10) { print("  \(path)") }
        throw CampusSyncError.config("resolvé esos \(plan.conflicts.count) conflictos y volvé a correr `campus-sync reubicar`.")
    }
    guard !plan.moves.isEmpty || newConfig != config else {
        print("No hay nada que mover.")
        return
    }
    if !arguments.contains("--si") {
        guard prompt("¿Muevo \(plan.moves.count) archivos y actualizo la configuración? (s/N)").lowercased() == "s" else {
            print("No se movió nada.")
            return
        }
    }

    let updated = try Relocator.execute(
        plan, manifests: manifests, from: oldRoot, to: newRoot, oldSubfolder: oldSubfolder, newSubfolder: newSubfolder)
    for manifest in updated { try store.save(manifest) }

    let oldNovedades = oldRoot.appending(path: "NOVEDADES.md")
    let newNovedades = newRoot.appending(path: "NOVEDADES.md")
    if oldRoot.standardizedFileURL != newRoot.standardizedFileURL,
        FileManager.default.fileExists(atPath: oldNovedades.path)
    {
        if FileManager.default.fileExists(atPath: newNovedades.path) {
            print("Dejé NOVEDADES.md en \(oldRoot.path): ya había uno en el destino.")
        } else {
            try FileManager.default.moveItem(at: oldNovedades, to: newNovedades)
        }
    }
    try newConfig.save()
    Relocator.removeEmptyDirectories(after: plan.moves, under: oldRoot)
    print("Listo: \(plan.moves.count) archivos movidos. Configuración actualizada. Corré `campus-sync status` para confirmar.")
}

@MainActor func logout() throws {
    let config = try loadConfig()
    let campus = try config.campus()
    try Keychain.deleteToken(account: campus.host() ?? config.campusURL)
    print("Token borrado del Llavero.")
}

// MARK: - Entrada

do {
    // Sin argumentos y sin configuración, lo útil es la configuración guiada.
    let noConfigYet = (try? Config.load()) == nil
    switch arguments.first ?? (noConfigYet && interactive ? "setup" : "help") {
    case "setup": try await setup()
    case "programar": try programSchedule()
    case "login": try await login()
    case "cursos", "courses": try await courses()
    case "status": try await status()
    case "sync": exit(try await sync())
    case "logout": try logout()
    case "reubicar": try relocate()
    case "help", "-h", "--help": print(usage)
    default:
        printError(usage)
        exit(64)
    }
} catch {
    fail(error)
}
