import Foundation
import Testing

@testable import CampusSyncCore

@Suite("Config: carpeta destino")
struct ConfigTests {
    @Test(
        "Rechaza links web y rutas relativas",
        arguments: [
            "https://drive.google.com/drive/folders/abc?usp=drive_link",
            "drive.google.com/drive/folders/abc",
            "Campus",
            "",
        ])
    func rejectsInvalid(raw: String) {
        #expect(throws: CampusSyncError.self) { try Config.validateDestination(raw) }
    }

    @Test("Acepta rutas absolutas y con ~")
    func acceptsLocalPaths() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try Config.validateDestination("~/Campus").path == home + "/Campus")
        #expect(try Config.validateDestination("  /tmp/x/../campus ").path == "/tmp/campus")
    }

    @Test("Expande ~ con la carpeta personal indicada, sin depender de $HOME")
    func expandsTildeWithInjectedHome() throws {
        let home = URL(filePath: "/Users/alguien", directoryHint: .isDirectory)
        #expect(try Config.validateDestination("~/Mi unidad/Campus", home: home).path == "/Users/alguien/Mi unidad/Campus")
        #expect(try Config.validateDestination("~", home: home).path == "/Users/alguien")
        #expect(throws: CampusSyncError.self) { try Config.validateDestination("~otro/Campus", home: home) }
    }

    @Test("Un sync con carpeta destino inexistente frena antes de pedir nada al campus")
    func engineRefusesMissingDestination() async throws {
        var config = Config(
            campusURL: "https://campus.example.edu",
            destination: try temporaryDirectory().appending(path: "no-existe").path)
        config.delayMilliseconds = 0
        let recorder = RequestRecorder()
        let fake = FakeCampus(contents: contentsJSON(apunteModified: 100, includeGuia: false))
        let recording: HTTPTransport = { request in
            recorder.record(request)
            return try await fake.send(request)
        }
        let client = try MoodleClient(baseURL: campus, token: token, send: recording, download: fake.download)
        let engine = SyncEngine(
            client: client, config: config, store: ManifestStore(directory: try temporaryDirectory()),
            log: Logger(redactor: Redactor()))
        await #expect(throws: CampusSyncError.self) { try await engine.run(apply: true) }
        #expect(recorder.requests.isEmpty)
        #expect(fake.downloads.isEmpty)
    }

    @Test("Un sync con destino inválido falla antes de tocar el disco")
    func engineRefusesInvalidDestination() async throws {
        var config = Config(campusURL: "https://campus.example.edu", destination: "https://drive.google.com/x")
        config.delayMilliseconds = 0
        let fake = FakeCampus(contents: contentsJSON(apunteModified: 100, includeGuia: false))
        let client = try MoodleClient(baseURL: campus, token: token, send: fake.send, download: fake.download)
        let engine = SyncEngine(
            client: client, config: config, store: ManifestStore(directory: try temporaryDirectory()),
            log: Logger(redactor: Redactor()))
        await #expect(throws: CampusSyncError.self) { try await engine.run(apply: true) }
        #expect(fake.downloads.isEmpty)
    }
}

@Suite("Mensajes de error")
struct ErrorMessageTests {
    @Test("Un permiso de Llavero cancelado explica cómo arreglarlo")
    func keychainCanceled() {
        #expect(CampusSyncError.keychain(-128).description.contains("campus-sync login"))
        #expect(CampusSyncError.keychain(-25308).description.contains("campus-sync login"))
        #expect(!CampusSyncError.keychain(-25300).description.contains("campus-sync login"))
    }
}
