import Foundation
import Testing

@testable import CampusSyncCore

@Suite("Relocator: mover un espejo sin volver a descargar")
struct RelocatorTests {
    @Test(
        "Nueva ruta relativa con y sin subcarpeta",
        arguments: [
            ("Análisis II/01 U1/a.pdf", nil, "Campus", "Análisis II/Campus/01 U1/a.pdf"),
            ("Análisis II/Campus/01 U1/a.pdf", "Campus", nil, "Análisis II/01 U1/a.pdf"),
            ("Análisis II/Campus/01 U1/a.pdf", "Campus", "Aula", "Análisis II/Aula/01 U1/a.pdf"),
            ("Análisis II/01 U1/a.pdf", nil, nil, "Análisis II/01 U1/a.pdf"),
        ] as [(String, String?, String?, String)])
    func newRelativePath(path: String, old: String?, new: String?, expected: String) {
        #expect(Relocator.newRelativePath(path, oldSubfolder: old, newSubfolder: new) == expected)
    }

    func entry(_ key: String, _ path: String) -> ManifestEntry {
        ManifestEntry(
            remote: RemoteFile(
                key: key, sectionName: "S", moduleName: "M", filename: (path as NSString).lastPathComponent,
                filesize: 1, timemodified: 1, fileurl: "https://campus.example.edu/f", relativePath: path),
            sha256: nil, downloadedAt: nil)
    }

    func write(_ text: String, _ path: String, under root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("Mueve archivos, versiones y enlaces; actualiza manifiestos; limpia solo carpetas propias vacías")
    func relocatesIntoSubjectFolders() throws {
        let old = try temporaryDirectory()
        let new = try temporaryDirectory()
        try write("a", "Análisis II/01 U1/apunte.pdf", under: old)
        try write("vieja", "Análisis II/01 U1/apunte (v 2026-09-01).pdf", under: old)
        try write("links", "Análisis II/_enlaces.md", under: old)
        try FileManager.default.createDirectory(at: old.appending(path: "Carpeta tuya vacía"), withIntermediateDirectories: true)
        try write("mío", "Análisis II/Resumen propio.pdf", under: new)  // material propio ya existente

        var manifest = Manifest(courseID: 7, courseTitle: "Análisis II")
        manifest.entries["1|/apunte.pdf"] = entry("1|/apunte.pdf", "Análisis II/01 U1/apunte.pdf")
        manifest.entries["2|/perdido.pdf"] = entry("2|/perdido.pdf", "Análisis II/01 U1/perdido.pdf")

        let plan = try Relocator.plan(manifests: [manifest], from: old, to: new, oldSubfolder: nil, newSubfolder: "Campus")
        #expect(plan.conflicts.isEmpty)
        #expect(plan.missing == ["Análisis II/01 U1/perdido.pdf"])
        #expect(
            Set(plan.moves.map(\.to)) == [
                "Análisis II/Campus/01 U1/apunte.pdf",
                "Análisis II/Campus/01 U1/apunte (v 2026-09-01).pdf",
                "Análisis II/Campus/_enlaces.md",
            ])

        let updated = try Relocator.execute(
            plan, manifests: [manifest], from: old, to: new, oldSubfolder: nil, newSubfolder: "Campus")
        Relocator.removeEmptyDirectories(after: plan.moves, under: old)

        #expect(updated[0].entries["1|/apunte.pdf"]?.relativePath == "Análisis II/Campus/01 U1/apunte.pdf")
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Análisis II/Campus/01 U1/apunte.pdf").path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Análisis II/Resumen propio.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: old.appending(path: "Análisis II").path))
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "Carpeta tuya vacía").path))
    }

    @Test("Si algo ya existe en el destino, no mueve nada")
    func refusesOnConflict() throws {
        let old = try temporaryDirectory()
        let new = try temporaryDirectory()
        try write("a", "M/01/a.pdf", under: old)
        try write("otro", "M/Campus/01/a.pdf", under: new)
        var manifest = Manifest(courseID: 1, courseTitle: "M")
        manifest.entries["1|/a.pdf"] = entry("1|/a.pdf", "M/01/a.pdf")

        let plan = try Relocator.plan(manifests: [manifest], from: old, to: new, oldSubfolder: nil, newSubfolder: "Campus")
        #expect(plan.conflicts == ["M/Campus/01/a.pdf"])
        #expect(throws: CampusSyncError.self) {
            try Relocator.execute(plan, manifests: [manifest], from: old, to: new, oldSubfolder: nil, newSubfolder: "Campus")
        }
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "M/01/a.pdf").path))
    }

    @Test("ManifestStore.all devuelve todos los cursos guardados")
    func storeAll() throws {
        let store = ManifestStore(directory: try temporaryDirectory())
        try store.save(Manifest(courseID: 20, courseTitle: "B"))
        try store.save(Manifest(courseID: 3, courseTitle: "A"))
        #expect(try store.all().map(\.courseID) == [3, 20])
    }
}
