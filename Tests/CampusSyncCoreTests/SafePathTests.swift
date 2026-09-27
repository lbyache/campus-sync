import Foundation
import Testing

@testable import CampusSyncCore

@Suite("SafePath: nombres del servidor → rutas locales seguras")
struct SafePathTests {
    @Test(
        "Separadores y puntos iniciales no sobreviven",
        arguments: [
            ("../../etc/passwd", "-..-etc-passwd"),
            ("/etc/passwd", "-etc-passwd"),
            ("..", "_"),
            (".", "_"),
            ("", "_"),
            ("   ", "_"),
            (".oculto", "oculto"),
            ("a\\b", "a-b"),
            ("Unidad 1: Límites", "Unidad 1- Límites"),
        ])
    func sanitizeComponent(input: String, expected: String) {
        #expect(SafePath.sanitizeComponent(input) == expected)
    }

    @Test("Quita caracteres de control e invisibles (incluido el de inversión de texto)")
    func stripsControlAndBidi() {
        // U+202E hace que "fdp.exe" se vea como "exe.pdf" en Finder.
        #expect(SafePath.sanitizeComponent("apunte\u{202E}fdp.exe") == "apuntefdp.exe")
        #expect(SafePath.sanitizeComponent("linea1\nlinea2\t\u{0}") == "linea1linea2")
    }

    @Test("Normaliza a NFC para que á compuesta y descompuesta sean el mismo nombre")
    func normalizesUnicode() {
        #expect(SafePath.sanitizeComponent("Ana\u{0301}lisis") == SafePath.sanitizeComponent("Análisis"))
    }

    @Test("Trunca nombres largos conservando la extensión")
    func truncatesLongNames() {
        let result = SafePath.sanitizeComponent(String(repeating: "á", count: 300) + ".pdf")
        #expect(result.utf8.count <= SafePath.maxComponentBytes)
        #expect(result.hasSuffix(".pdf"))
    }

    @Test("filepath de Moodle: descarta . y .. y sanea cada parte")
    func sanitizeDirectory() {
        #expect(SafePath.sanitizeDirectory("/").isEmpty)
        #expect(SafePath.sanitizeDirectory(nil).isEmpty)
        #expect(SafePath.sanitizeDirectory("/practica/tp 1/") == ["practica", "tp 1"])
        #expect(SafePath.sanitizeDirectory("/../../x/./y/") == ["x", "y"])
    }

    @Test("resolve rechaza rutas que escapan de la carpeta destino")
    func resolveRejectsEscapes() throws {
        let base = try temporaryDirectory()
        #expect(throws: CampusSyncError.self) { try SafePath.resolve("../afuera.txt", under: base) }
        #expect(throws: CampusSyncError.self) { try SafePath.resolve("a/../../afuera.txt", under: base) }
        let inside = try SafePath.resolve("Materia/01 Unidad/apunte.pdf", under: base)
        #expect(inside.path.hasSuffix("Materia/01 Unidad/apunte.pdf"))
    }

    @Test("resolve rechaza escapar por un enlace simbólico existente")
    func resolveRejectsSymlinkEscape() throws {
        let base = try temporaryDirectory()
        let outside = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(at: base.appending(path: "trampa"), withDestinationURL: outside)
        #expect(throws: CampusSyncError.self) { try SafePath.resolve("trampa/archivo.pdf", under: base) }
    }

    @Test("Nombre versionado antes de la extensión")
    func versionedName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
        #expect(SafePath.versionedName("M/01 U/apunte.pdf", date: date) == "M/01 U/apunte (v 2026-09-01).pdf")
        #expect(SafePath.versionedName("M/LEEME", date: date) == "M/LEEME (v 2026-09-01)")
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "campus-sync-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
