import Foundation
import Synchronization
import Testing

@testable import CampusSyncCore

/// Campus simulado: responde a las funciones de la API y sirve archivos cuyo contenido
/// incluye la versión del archivo, para distinguir descargas viejas de nuevas.
final class FakeCampus: Sendable {
    struct State {
        var contents: String
        var downloads: [String] = []
    }
    private let state: Mutex<State>

    init(contents: String) { state = Mutex(State(contents: contents)) }

    func setContents(_ json: String) { state.withLock { $0.contents = json } }
    var downloads: [String] { state.withLock { $0.downloads } }

    var send: HTTPTransport {
        { [self] request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let json: String =
                switch true {
                case body.contains("wsfunction=core_webservice_get_site_info"):
                    #"{"userid": 7, "sitename": "Campus", "fullname": "Ana"}"#
                case body.contains("wsfunction=core_enrol_get_users_courses"):
                    #"[{"id": 42, "fullname": "Análisis II"}, {"id": 99, "fullname": "Excluida"}]"#
                default:
                    state.withLock { $0.contents }
                }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    var download: DownloadTransport {
        { [self] request in
            let url = request.url!
            #expect(url.query?.contains("token=") == true)
            state.withLock { $0.downloads.append(url.path) }
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("contenido de \(url.path) \(url.query ?? "")".utf8).write(to: file)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/pdf"])!
            return (file, response)
        }
    }
}

func contentsJSON(apunteModified: Int, includeGuia: Bool) -> String {
    let guia =
        includeGuia
        ? """
        ,{"type": "file", "filename": "guia.pdf", "filepath": "/", "filesize": 5, "timemodified": 100,
          "fileurl": "https://campus.example.edu/webservice/pluginfile.php/1/mod_folder/content/0/guia.pdf"}
        """ : ""
    return """
        [{"id": 1, "name": "Unidad 1", "section": 1, "modules": [
          {"id": 300, "name": "Material", "modname": "folder", "contents": [
            {"type": "file", "filename": "apunte.pdf", "filepath": "/", "filesize": 10, "timemodified": \(apunteModified),
             "fileurl": "https://campus.example.edu/webservice/pluginfile.php/1/mod_folder/content/0/apunte.pdf?v=\(apunteModified)"}
            \(guia)
          ]},
          {"id": 301, "name": "Clase grabada", "modname": "url", "contents": [
            {"type": "url", "filename": "x", "fileurl": "https://www.youtube.com/watch?v=abc"}
          ]}
        ]}]
        """
}

@Suite("SyncEngine de punta a punta con un campus simulado")
struct SyncEngineTests {
    @Test("Baja, es idempotente, versiona lo modificado y reporta lo retirado sin borrar")
    func fullCycle() async throws {
        let destination = try temporaryDirectory()
        let store = ManifestStore(directory: try temporaryDirectory())
        var config = Config(campusURL: "https://campus.example.edu", destination: destination.path)
        config.delayMilliseconds = 0
        config.excludeCourses = [99]
        config.aliases = ["42": "Análisis II"]

        let fake = FakeCampus(contents: contentsJSON(apunteModified: 100, includeGuia: true))
        let client = try MoodleClient(baseURL: campus, token: token, send: fake.send, download: fake.download)
        let engine = SyncEngine(client: client, config: config, store: store, log: Logger(redactor: Redactor(secrets: [token])))
        let folder = destination.appending(path: "Análisis II/01 Unidad 1/Material")

        // 1. status no escribe nada
        let preview = try await engine.run(apply: false)
        #expect(preview.courses.map(\.course.id) == [42])
        #expect(preview.courses[0].plan.new.count == 2)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try store.load(courseID: 42) == nil)

        // 2. primer sync: baja todo y escribe los enlaces
        let first = try await engine.run(apply: true)
        #expect(first.courses[0].downloaded.count == 2)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "apunte.pdf").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "guia.pdf").path))
        let links = try String(contentsOf: destination.appending(path: "Análisis II/_enlaces.md"), encoding: .utf8)
        #expect(links.contains("[Clase grabada](https://www.youtube.com/watch?v=abc)"))

        // 3. segundo sync sin cambios: no descarga nada
        let downloadsBefore = fake.downloads.count
        let second = try await engine.run(apply: true)
        #expect(second.courses[0].downloaded.isEmpty)
        #expect(!second.hasChanges)
        #expect(fake.downloads.count == downloadsBefore)

        // 4. el campus modifica apunte.pdf y retira guia.pdf
        fake.setContents(contentsJSON(apunteModified: 1_767_225_600, includeGuia: false))
        let third = try await engine.run(apply: true)
        #expect(third.courses[0].plan.modified.map(\.remote.filename) == ["apunte.pdf"])
        #expect(third.courses[0].plan.retired.map(\.filename) == ["guia.pdf"])

        let apunte = try String(contentsOf: folder.appending(path: "apunte.pdf"), encoding: .utf8)
        #expect(apunte.contains("v=1767225600"))  // la versión nueva
        let versions = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("apunte (v ") }
        #expect(versions.count == 1)  // la vieja se conserva al lado
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "guia.pdf").path))  // retirado ≠ borrado

        // 5. el retiro se reporta una sola vez
        let fourth = try await engine.run(apply: true)
        #expect(fourth.courses[0].plan.retired.isEmpty)

        // 6. si borrás un archivo del espejo, vuelve
        try FileManager.default.removeItem(at: folder.appending(path: "apunte.pdf"))
        let fifth = try await engine.run(apply: true)
        #expect(fifth.courses[0].plan.missingLocally.map(\.filename) == ["apunte.pdf"])
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "apunte.pdf").path))

        // NOVEDADES.md: la corrida más reciente queda arriba
        let block = try #require(Reporter.novedadesBlock(third))
        let novedades = destination.appending(path: "NOVEDADES.md")
        try Reporter.prependNovedades(try #require(Reporter.novedadesBlock(first)), at: novedades)
        try Reporter.prependNovedades(block, at: novedades)
        let text = try String(contentsOf: novedades, encoding: .utf8)
        #expect(text.hasPrefix("# Novedades del campus\n\n## "))
        #expect(text.components(separatedBy: "# Novedades del campus").count == 2)
        #expect(text.range(of: "Modificado")!.lowerBound < text.range(of: "Nuevo")!.lowerBound)
    }

    @Test("Un token vencido corta el sync entero en lugar de fallar archivo por archivo")
    func invalidTokenAborts() async throws {
        var config = Config(campusURL: "https://campus.example.edu", destination: try temporaryDirectory().path)
        config.delayMilliseconds = 0
        let fake = FakeCampus(contents: contentsJSON(apunteModified: 100, includeGuia: false))
        let expired: DownloadTransport = { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data(#"{"error":"Token inválido","errorcode":"invalidtoken"}"#.utf8).write(to: file)
            return (
                file,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json; charset=utf-8"])!
            )
        }
        let client = try MoodleClient(baseURL: campus, token: token, send: fake.send, download: expired)
        let engine = SyncEngine(
            client: client, config: config, store: ManifestStore(directory: try temporaryDirectory()),
            log: Logger(redactor: Redactor()))
        await #expect(throws: CampusSyncError.invalidToken) { try await engine.run(apply: true) }
    }
}
