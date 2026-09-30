import Foundation
import Testing

@testable import CampusSyncCore

@Suite("Asistente: URL del campus")
struct CampusURLTests {
    @Test(
        "Lleva lo que la gente pega a la raíz de Moodle",
        arguments: [
            ("campus.example.edu", "https://campus.example.edu"),
            ("https://campus.example.edu/", "https://campus.example.edu"),
            ("http://campus.example.edu/login/index.php", "https://campus.example.edu"),
            ("https://campus.example.edu/my/", "https://campus.example.edu"),
            ("https://campus.example.edu/course/view.php?id=5328#section-2", "https://campus.example.edu"),
            ("https://example.edu/moodle/login/index.php", "https://example.edu/moodle"),
            ("  https://example.edu/moodle/  ", "https://example.edu/moodle"),
        ])
    func normalizes(input: String, expected: String) throws {
        #expect(try CampusURL.normalize(input).absoluteString == expected)
    }

    @Test("Rechaza lo que no es una dirección", arguments: ["", "   ", "campus", "https://"])
    func rejects(input: String) {
        #expect(throws: CampusSyncError.self) { try CampusURL.normalize(input) }
    }
}

@Suite("Asistente: configuración pública del sitio")
struct PublicSiteConfigTests {
    @Test("Lee la respuesta de tool_mobile_get_public_config")
    func decodes() throws {
        let json = #"""
            [{"error":false,"data":{"wwwroot":"https://campus.example.edu","sitename":"Campus Virtual",
              "enablewebservices":1,"enablemobilewebservice":1,"typeoflogin":1}}]
            """#
        let config = try PublicSiteConfig.decode(Data(json.utf8))
        #expect(config.sitename == "Campus Virtual")
        #expect(config.mobileAccessEnabled)
        #expect(config.usesPasswordLogin)
    }

    @Test("Detecta servicio móvil apagado y login por SSO")
    func detectsLimits() throws {
        let json = #"[{"error":false,"data":{"enablewebservices":1,"enablemobilewebservice":0,"typeoflogin":2}}]"#
        let config = try PublicSiteConfig.decode(Data(json.utf8))
        #expect(!config.mobileAccessEnabled)
        #expect(!config.usesPasswordLogin)
    }

    @Test("Una respuesta de error o que no es Moodle es un error claro")
    func rejectsGarbage() {
        #expect(throws: CampusSyncError.self) {
            try PublicSiteConfig.decode(Data(#"[{"error":true,"exception":{"message":"x"}}]"#.utf8))
        }
        #expect(throws: CampusSyncError.self) { try PublicSiteConfig.decode(Data("<html>".utf8)) }
    }

    @Test("La consulta pública no manda credenciales")
    func requestHasNoCredentials() async throws {
        let recorder = RequestRecorder()
        _ = try await MoodleClient.publicConfig(
            baseURL: campus,
            send: fakeTransport(json: #"[{"error":false,"data":{"sitename":"X"}}]"#, recorder: recorder))
        let request = try #require(recorder.requests.first)
        #expect(
            request.url?.absoluteString
                == "https://campus.example.edu/lib/ajax/service-nologin.php?info=tool_mobile_get_public_config")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(!body.contains("token"))
    }
}

@Suite("Asistente: nombres cortos de cursos")
struct CourseNamingTests {
    @Test(
        "Quita el código de asignatura y el período",
        arguments: [
            ("ASIG00194 - Algoritmos y Estructuras de Datos-2/2026", "Algoritmos y Estructuras de Datos"),
            (
                "ASIG00195 - Fundamentos de Estadística y Probabilidad - 2/2026",
                "Fundamentos de Estadística y Probabilidad"
            ),
            ("ASIG00196 - Cálculo y análisis matemático-2/2026", "Cálculo y análisis matemático"),
            (
                "ASIG00297 - Transformación Digital en las Organizaciones_2/2026",
                "Transformación Digital en las Organizaciones"
            ),
            ("MAT101: Análisis II (2026)", "Análisis II"),
            ("Física I 2C 2026", "Física I"),
            ("Biblioteca", "Biblioteca"),
            ("SIU Autogestión: tutoriales para estudiantes", "SIU Autogestión: tutoriales para estudiantes"),
            ("2026", "2026"),
        ])
    func suggests(title: String, expected: String) {
        #expect(CourseNaming.suggestedAlias(for: title) == expected)
    }
}

@Suite("Asistente: selección por números")
struct SelectionTests {
    @Test("Números sueltos y rangos")
    func parses() throws {
        #expect(try Selection.parse("", count: 5).isEmpty)
        #expect(try Selection.parse("2, 5", count: 5) == [2, 5])
        #expect(try Selection.parse("1-3 5", count: 5) == [1, 2, 3, 5])
    }

    @Test("Fuera de rango o mal escrito es un error", arguments: ["0", "6", "3-1", "a", "2-", "1-2-3"])
    func rejects(text: String) {
        #expect(throws: CampusSyncError.self) { try Selection.parse(text, count: 5) }
    }
}

@Suite("Asistente: carpetas en la nube")
struct CloudFoldersTests {
    @Test("Detecta Google Drive, OneDrive, Dropbox e iCloud; siempre ofrece Documentos")
    func detects() throws {
        let home = try temporaryDirectory()
        let storage = home.appending(path: "Library/CloudStorage")
        for path in [
            "GoogleDrive-ana@example.com/Mi unidad", "GoogleDrive-ana@example.com/Unidades compartidas",
            "OneDrive-Personal", "Dropbox",
        ] {
            try FileManager.default.createDirectory(at: storage.appending(path: path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)

        let labels = CloudFolders.candidates(home: home).map(\.label)
        #expect(
            labels == [
                "Dropbox", "Google Drive (ana@example.com)", "OneDrive (OneDrive-Personal)", "iCloud Drive",
                "Documentos (solo en esta Mac)",
            ])
    }

    @Test("Guarda la ruta con ~ cuando está dentro de la carpeta personal")
    func displayPath() {
        let home = URL(filePath: "/Users/ana", directoryHint: .isDirectory)
        #expect(CloudFolders.displayPath(URL(filePath: "/Users/ana/Documents/Campus"), home: home) == "~/Documents/Campus")
        #expect(CloudFolders.displayPath(URL(filePath: "/Volumes/USB/Campus"), home: home) == "/Volumes/USB/Campus")
    }
}

@Suite("Asistente: tarea programada")
struct LaunchAgentTests {
    func decode(_ data: Data) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("Semanal: domingo 10:00, con el programa y el log indicados")
    func weekly() throws {
        let plist = try decode(
            LaunchAgent.plist(
                executable: "/Users/ana/.local/bin/campus-sync", schedule: .defaultWeekly,
                logPath: "/Users/ana/Library/Logs/campus-sync.log"))
        #expect(plist["Label"] as? String == "local.campus-sync")
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/ana/.local/bin/campus-sync", "sync"])
        #expect(plist["StartCalendarInterval"] as? [String: Int] == ["Weekday": 0, "Hour": 10, "Minute": 0])
    }

    @Test("Diaria sin día de la semana; una ruta con caracteres raros no rompe el XML")
    func dailyAndEscaping() throws {
        let odd = "/Users/ana/Mis <cosas> & \"más\"/campus-sync"
        let plist = try decode(LaunchAgent.plist(executable: odd, schedule: .defaultDaily, logPath: "/tmp/log"))
        #expect(plist["StartCalendarInterval"] as? [String: Int] == ["Hour": 8, "Minute": 0])
        #expect((plist["ProgramArguments"] as? [String])?.first == odd)
    }

    @Test("Manual no genera tarea")
    func manual() {
        #expect(throws: CampusSyncError.self) {
            try LaunchAgent.plist(executable: "/x", schedule: .manual, logPath: "/tmp/log")
        }
        #expect(Schedule.manual.description.contains("campus-sync sync"))
        #expect(Schedule.defaultWeekly.description == "una vez por semana, domingo 10:00")
    }
}
