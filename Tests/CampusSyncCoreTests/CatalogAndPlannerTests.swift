import Foundation
import Testing

@testable import CampusSyncCore

func fixtureSections() throws -> [CourseSection] {
    let url = try #require(Bundle.module.url(forResource: "course_contents", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([CourseSection].self, from: Data(contentsOf: url))
}

@Suite("RemoteCatalog: contenidos del curso → archivos y enlaces")
struct RemoteCatalogTests {
    @Test("Estructura de carpetas, módulos ocultos y enlaces")
    func buildsCatalog() throws {
        let catalog = RemoteCatalog.build(courseFolder: "Análisis II", sections: try fixtureSections())
        let paths = catalog.files.map(\.relativePath)

        #expect(paths.contains("Análisis II/00 General/Programa 2026.pdf"))  // recurso de un archivo: plano
        #expect(paths.contains("Análisis II/01 Unidad 1- Límites/Material de la unidad/apunte.pdf"))
        #expect(paths.contains("Análisis II/01 Unidad 1- Límites/Material de la unidad/practica/ejercicios.pdf"))
        #expect(!catalog.files.contains { $0.filename == "solucionario.pdf" })  // uservisible == false
        #expect(catalog.links.map(\.name) == ["Video de la cátedra", "Enlace peligroso"])
    }

    @Test("Un nombre malicioso queda contenido en la carpeta de la materia")
    func maliciousNameStaysInside() throws {
        let catalog = RemoteCatalog.build(courseFolder: "Análisis II", sections: try fixtureSections())
        let hostile = try #require(catalog.files.first { $0.filename.contains("authorized_keys") })
        // ".." dentro de un nombre es inofensivo; lo peligroso es un componente ".." o vacío.
        let components = hostile.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        #expect(!components.contains { $0 == ".." || $0 == "." || $0.isEmpty })
        #expect(components.count == 4)
        #expect(hostile.relativePath.hasPrefix("Análisis II/01 Unidad 1- Límites/Material de la unidad/"))
        #expect(throws: Never.self) { try SafePath.resolve(hostile.relativePath, under: temporaryDirectory()) }
    }
}

@Suite("SyncPlanner: qué bajar, qué cambió, qué se retiró")
struct SyncPlannerTests {
    func remote(_ key: String, path: String, size: Int = 10, modified: Int = 100) -> RemoteFile {
        RemoteFile(
            key: key, sectionName: "S", moduleName: "M", filename: (path as NSString).lastPathComponent,
            filesize: size, timemodified: modified, fileurl: "https://campus.example.edu/f/\(key)", relativePath: path)
    }

    func manifest(_ files: [RemoteFile]) -> Manifest {
        var manifest = Manifest(courseID: 1, courseTitle: "Materia")
        for file in files {
            manifest.entries[file.key] = ManifestEntry(remote: file, sha256: nil, downloadedAt: nil)
        }
        return manifest
    }

    @Test("Sin manifiesto, todo es nuevo")
    func everythingNew() {
        let plan = SyncPlanner.plan(remote: [remote("1|/a.pdf", path: "M/a.pdf")], manifest: nil) { _ in false }
        #expect(plan.new.count == 1)
        #expect(plan.pendingDownloads == 1)
    }

    @Test("Detecta modificados, borrados localmente, retirados y sin cambios")
    func classifies() {
        let a = remote("1|/a.pdf", path: "M/a.pdf")
        let b = remote("2|/b.pdf", path: "M/b.pdf")
        let c = remote("3|/c.pdf", path: "M/c.pdf")
        let d = remote("4|/d.pdf", path: "M/d.pdf")
        let known = manifest([a, b, c, d])

        let changedB = remote("2|/b.pdf", path: "M/b.pdf", modified: 200)
        let plan = SyncPlanner.plan(remote: [a, changedB, c], manifest: known) { $0 != "M/c.pdf" }

        #expect(plan.unchanged.map(\.key) == ["1|/a.pdf"])
        #expect(plan.modified.map(\.remote.key) == ["2|/b.pdf"])
        #expect(plan.missingLocally.map(\.key) == ["3|/c.pdf"])
        #expect(plan.retired.map(\.key) == ["4|/d.pdf"])
        #expect(plan.new.isEmpty)
    }

    @Test("Un cambio de tamaño también cuenta como modificación")
    func sizeChange() {
        let a = remote("1|/a.pdf", path: "M/a.pdf")
        let plan = SyncPlanner.plan(remote: [remote("1|/a.pdf", path: "M/a.pdf", size: 99)], manifest: manifest([a])) { _ in true
        }
        #expect(plan.modified.count == 1)
    }

    @Test("Un archivo ya retirado no se vuelve a reportar")
    func retiredOnce() {
        let a = remote("1|/a.pdf", path: "M/a.pdf")
        var known = manifest([a])
        known.entries["1|/a.pdf"]?.retiredAt = Date()
        #expect(SyncPlanner.plan(remote: [], manifest: known) { _ in true }.retired.isEmpty)
    }

    @Test("Conserva la ruta guardada aunque cambie el nombre de la sección")
    func stablePaths() {
        let original = remote("1|/a.pdf", path: "M/01 Viejo nombre/a.pdf")
        let renamed = remote("1|/a.pdf", path: "M/01 Nombre nuevo/a.pdf")
        let plan = SyncPlanner.plan(remote: [renamed], manifest: manifest([original])) { _ in true }
        #expect(plan.unchanged.first?.relativePath == "M/01 Viejo nombre/a.pdf")
    }

    @Test("Desambigua choques de nombre, incluso por mayúsculas")
    func collisions() {
        let existing = remote("1|/a.pdf", path: "M/S/a.pdf")
        let sameName = remote("2|/a.pdf", path: "M/S/a.pdf")
        let upperCase = remote("3|/A.pdf", path: "M/S/A.pdf")
        let plan = SyncPlanner.plan(remote: [existing, sameName, upperCase], manifest: manifest([existing])) { _ in true }

        let newPaths = plan.new.map(\.relativePath)
        #expect(newPaths == ["M/S/a (2).pdf", "M/S/A (3).pdf"])
        #expect(Set(newPaths.map { $0.lowercased() }).count == newPaths.count)
    }
}
