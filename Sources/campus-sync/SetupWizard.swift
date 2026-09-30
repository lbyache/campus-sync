import CampusSyncCore
import Foundation

// `campus-sync setup`: la puerta de entrada para quien no quiere tocar rutas ni archivos de
// configuración. Pregunta en lenguaje llano, ofrece opciones numeradas y valida cada respuesta.

/// Ruta real del programa que está corriendo (para la tarea programada).
func currentExecutable() -> String {
    (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath().standardizedFileURL.path
}

/// Pide el token: por usuario y contraseña, o a mano si el campus usa SSO.
@MainActor func obtainToken(campus: URL, passwordLogin: Bool) async throws -> String {
    if !passwordLogin || arguments.contains("--token") {
        print(
            """
            Este campus inicia sesión por otra página (SSO), así que el acceso se copia a mano:
              1. Entrá al campus en el navegador.
              2. Abrí tu perfil › Preferencias › Claves de seguridad.
              3. Copiá la clave del servicio "Moodle mobile web service".
            """)
        guard let token = readSecret("Clave (no se muestra): ") else {
            throw CampusSyncError.config("clave vacía o sin terminal interactiva.")
        }
        return token
    }
    for attempt in 1...3 {
        let username = prompt("Usuario del campus")
        guard !username.isEmpty, let password = readSecret("Contraseña (no se muestra ni se guarda): ") else {
            throw CampusSyncError.config("usuario o contraseña vacíos, o sin terminal interactiva.")
        }
        do {
            return try await MoodleClient.requestToken(baseURL: campus, username: username, password: password)
        } catch CampusSyncError.invalidLogin(let message) where attempt < 3 {
            printError("No entró: \(message) Probá de nuevo (\(attempt) de 3).")
        }
    }
    throw CampusSyncError.invalidLogin("tres intentos fallidos.")
}

@MainActor func setup() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let existing = try Config.load()
    print(
        """
        campus-sync · configuración guiada

        Voy a preguntarte cinco cosas: tu campus, tu usuario, dónde guardar el material, qué cursos
        bajar y cada cuánto revisar novedades. Tu contraseña no se guarda: se usa una vez para
        obtener un acceso que queda en el Llavero de macOS.

        """)

    // 1. Campus
    var campus: URL?
    var site: PublicSiteConfig?
    while campus == nil {
        let answer = prompt("1/5 · Dirección del campus (la que ves en el navegador)", default: existing?.campusURL)
        do {
            let url = try CampusURL.normalize(answer)
            print("Revisando \(url.absoluteString)…")
            let config = try await MoodleClient.publicConfig(baseURL: url)
            guard config.mobileAccessEnabled else {
                throw CampusSyncError.config(
                    "este campus no tiene habilitado el acceso de la app móvil de Moodle, y campus-sync lo "
                        + "necesita. Es una opción de la institución: podés pedirle a soporte que active los "
                        + "servicios web para dispositivos móviles.")
            }
            // Se usa la raíz que declara el propio Moodle, si es del mismo servidor y por https.
            if let root = config.wwwroot.flatMap(URL.init(string:)), root.scheme == "https",
                root.host()?.lowercased() == url.host()?.lowercased()
            {
                campus = root
            } else {
                campus = url
            }
            site = config
            print("✔ \(config.sitename ?? url.host() ?? "El campus") acepta la app móvil.\n")
        } catch {
            printError("\(error)")
        }
    }
    guard let campus, let site else { return }

    // 2. Sesión
    print("2/5 · Iniciar sesión")
    let token = try await obtainToken(campus: campus, passwordLogin: site.usesPasswordLogin)
    redactor = Redactor(secrets: [token])
    let client = try MoodleClient(baseURL: campus, token: token)
    let me = try await client.siteInfo()
    try Keychain.saveToken(token, account: campus.host() ?? campus.absoluteString)
    print("✔ Sesión de \(me.fullname ?? me.username ?? "?"). El acceso quedó en el Llavero.\n")

    // 3. Carpeta
    print("3/5 · ¿Dónde guardo el material?")
    var options: [(label: String, url: URL, isCurrent: Bool)] = []
    if let current = try? existing?.destinationDirectory(), FileManager.default.fileExists(atPath: current.path) {
        options.append(("Seguir usando la carpeta actual", current, true))
    }
    options += CloudFolders.candidates(home: home).map { ($0.label, $0.url, false) }
    for (index, option) in options.enumerated() {
        print("  \(index + 1). \(option.label) — \(CloudFolders.displayPath(option.url, home: home))")
    }
    print("  \(options.count + 1). Otra carpeta (escribir la ruta)")
    if options.contains(where: { $0.label.hasPrefix("Google Drive") || $0.label.hasPrefix("OneDrive") }) {
        print("  Consejo: una carpeta en la nube te deja ver el material también en el teléfono.")
    }

    var destination: URL?
    while destination == nil {
        let answer = prompt("Número", default: "1")
        guard let number = Int(answer), (1...(options.count + 1)).contains(number) else {
            printError("Elegí un número de la lista.")
            continue
        }
        do {
            if number == options.count + 1 {
                let typed = prompt("Ruta de la carpeta (en la Mac, no un link web)")
                destination = try Config.validateDestination(typed)
            } else if options[number - 1].isCurrent {
                destination = options[number - 1].url
            } else {
                let name = prompt("Nombre de la carpeta que creo ahí adentro", default: "Campus")
                destination = options[number - 1].url.appending(path: SafePath.sanitizeComponent(name))
            }
        } catch {
            printError("\(error)")
        }
    }
    guard let destination else { return }
    if !FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    let destinationText = CloudFolders.displayPath(destination, home: home)
    let keepsLayout = (try? existing?.destinationDirectory())?.standardizedFileURL == destination.standardizedFileURL
    if let existing, !keepsLayout, !((try? ManifestStore().all()) ?? []).isEmpty {
        print(
            "Ojo: ya tenías material bajado en \(existing.destination). Para moverlo sin volver a "
                + "descargarlo, cancelá (Ctrl+C) y usá `campus-sync reubicar`.")
    }
    print("✔ El material va a \(destinationText)\n")

    // 4. Cursos
    print("4/5 · Tus cursos")
    let courses = try await client.courses(userID: me.userid)
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    let suggested = courses.map { CourseNaming.suggestedAlias(for: $0.title) }
    for (index, course) in courses.enumerated() {
        let original = suggested[index] == course.title ? "" : "   (\(course.title))"
        print("  \(index + 1). \(suggested[index])\(original)")
    }
    var excluded = Set<Int>()
    while true {
        let answer = prompt("¿Alguno que NO quieras bajar? Números separados por coma (Enter = todos)", default: "")
        do {
            excluded = try Selection.parse(answer, count: courses.count)
            break
        } catch {
            printError("\(error)")
        }
    }
    let useShortNames = prompt("¿Uso esos nombres para las carpetas? (S/n)", default: "s").lowercased() != "n"
    print("✔ Se bajan \(courses.count - excluded.count) de \(courses.count) cursos.\n")

    // 5. Frecuencia
    print("5/5 · ¿Cada cuánto reviso novedades?")
    let schedules: [Schedule] = [.defaultWeekly, .defaultDaily, .manual]
    for (index, schedule) in schedules.enumerated() {
        print("  \(index + 1). \(schedule.description)\(index == 0 ? " (recomendado)" : "")")
    }
    var schedule = Schedule.defaultWeekly
    while true {
        if let number = Int(prompt("Número", default: "1")), (1...schedules.count).contains(number) {
            schedule = schedules[number - 1]
            break
        }
        printError("Elegí 1, 2 o 3.")
    }

    // Guardar
    var config = keepsLayout ? (existing ?? Config(campusURL: "", destination: "")) : Config(campusURL: "", destination: "")
    config.campusURL = campus.absoluteString
    config.destination = destinationText
    config.includeCourses = nil
    config.excludeCourses = excluded.isEmpty ? nil : excluded.sorted().map { courses[$0 - 1].id }
    if useShortNames {
        var aliases = config.aliases ?? [:]
        for (index, course) in courses.enumerated() where suggested[index] != course.title {
            aliases[String(course.id)] = aliases[String(course.id)] ?? suggested[index]
        }
        config.aliases = aliases.isEmpty ? nil : aliases
    }
    try config.save()

    let executable = currentExecutable()
    if schedule != .manual && executable.contains("/.build/") {
        print("Aviso: estás corriendo campus-sync desde la carpeta de compilación; conviene instalarlo con scripts/install.sh.")
    }
    try LaunchAgent.apply(schedule, executable: executable, home: home)
    print("✔ Revisión de novedades: \(schedule.description).\n")

    if prompt("¿Bajo el material ahora? (S/n)", default: "s").lowercased() != "n" {
        _ = try await sync()
    }
    print(
        """

        Listo. Cuando quieras:
          campus-sync status   ¿tengo todo?
          campus-sync sync     buscar novedades ahora
          campus-sync setup    cambiar estas respuestas
        """)
}

@MainActor func programSchedule() throws {
    let schedule: Schedule =
        arguments.contains("--diario") ? .defaultDaily : arguments.contains("--manual") ? .manual : .defaultWeekly
    try LaunchAgent.apply(schedule, executable: currentExecutable(), home: FileManager.default.homeDirectoryForCurrentUser)
    print("✔ Sync programado: \(schedule.description) (log: ~/Library/Logs/campus-sync.log)")
}
