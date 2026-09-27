import Foundation

/// Un archivo descargable del campus, con la ruta local que le corresponde.
public struct RemoteFile: Sendable, Equatable {
    /// Identidad estable entre corridas: módulo + ruta + nombre dentro del módulo.
    public let key: String
    public let sectionName: String
    public let moduleName: String
    public let filename: String
    public let filesize: Int
    public let timemodified: Int
    public let fileurl: String
    /// Ruta propuesta relativa a la carpeta destino. El planificador puede
    /// reemplazarla por la guardada en el manifiesto o desambiguarla.
    public var relativePath: String
}

/// Un enlace externo del campus (módulo `url`): se lista, no se descarga.
public struct RemoteLink: Sendable, Equatable {
    public let sectionName: String
    public let name: String
    public let url: String
}

public struct RemoteCatalog: Sendable {
    public var files: [RemoteFile]
    public var links: [RemoteLink]

    /// Aplana secciones → módulos → contenidos.
    ///
    /// Estructura local: `<Materia>/<NN Sección>/<archivo>` para un recurso de un
    /// solo archivo, y `<Materia>/<NN Sección>/<Módulo>/<subcarpetas>/<archivo>`
    /// para carpetas, páginas y recursos con varios archivos.
    /// `coursePath` son los componentes de la carpeta del curso (p. ej. `["Análisis II", "Campus"]`);
    /// se sanean acá igual, por si vienen de otro lado.
    public static func build(coursePath: [String], sections: [CourseSection]) -> RemoteCatalog {
        var files: [RemoteFile] = []
        var links: [RemoteLink] = []
        let courseRoot = coursePath.map(SafePath.sanitizeComponent)

        for (index, section) in sections.enumerated() {
            let number = section.section ?? index
            let sectionTitle = nonEmpty(section.name) ?? "Sección \(number)"
            let sectionFolder = SafePath.sanitizeComponent(String(format: "%02d ", number) + sectionTitle)

            for module in section.courseModules where module.uservisible != false {
                let moduleTitle = nonEmpty(module.name) ?? "\(module.modname) \(module.id)"
                let contents = module.contents ?? []

                if module.modname == "url" {
                    for content in contents where content.type == "url" {
                        if let url = content.fileurl ?? module.url {
                            links.append(RemoteLink(sectionName: sectionTitle, name: moduleTitle, url: url))
                        }
                    }
                    continue
                }

                let downloadable = contents.filter { $0.type == "file" && $0.fileurl != nil && $0.filename != nil }
                let flat = module.modname == "resource" && downloadable.count == 1

                for content in downloadable {
                    guard let fileurl = content.fileurl, let filename = content.filename else { continue }
                    var components = courseRoot + [sectionFolder]
                    if !flat {
                        components.append(SafePath.sanitizeComponent(moduleTitle))
                        components += SafePath.sanitizeDirectory(content.filepath)
                    }
                    components.append(SafePath.sanitizeComponent(filename))

                    files.append(
                        RemoteFile(
                            key: "\(module.id)|\(content.filepath ?? "/")\(filename)",
                            sectionName: sectionTitle,
                            moduleName: moduleTitle,
                            filename: filename,
                            filesize: content.filesize ?? 0,
                            timemodified: content.timemodified ?? 0,
                            fileurl: fileurl,
                            relativePath: SafePath.join(components)
                        ))
                }
            }
        }
        return RemoteCatalog(files: files, links: links)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
