import Foundation

/// Mueve un espejo ya descargado a otra carpeta destino o a otra estructura (con o sin subcarpeta
/// por curso) sin volver a bajar nada, y actualiza los manifiestos para que el próximo sync lo
/// reconozca.
public enum Relocator {
    public struct Move: Sendable, Equatable {
        public let from: String
        public let to: String
    }

    public struct Plan: Sendable, Equatable {
        /// Movimientos de archivos conocidos (en los manifiestos) y de los `_enlaces.md`.
        public var moves: [Move]
        /// Archivos que el manifiesto conoce pero que no están en disco: se omiten.
        public var missing: [String]
        /// Destinos que ya existen: si hay alguno, no se mueve nada.
        public var conflicts: [String]
    }

    /// PURO: nueva ruta relativa. El primer componente es la carpeta del curso; si la ruta tenía la
    /// subcarpeta vieja se reemplaza por la nueva.
    public static func newRelativePath(_ path: String, oldSubfolder: String?, newSubfolder: String?) -> String {
        var components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return path }
        let course = components.removeFirst()
        if let old = Config.subfolderComponents(oldSubfolder).first, components.first == old {
            components.removeFirst()
        }
        return SafePath.join([course] + Config.subfolderComponents(newSubfolder) + components)
    }

    /// Arma el plan comprobando qué existe en el origen y qué ocuparía lugar en el destino.
    public static func plan(
        manifests: [Manifest],
        from oldRoot: URL,
        to newRoot: URL,
        oldSubfolder: String?,
        newSubfolder: String?
    ) throws -> Plan {
        var candidates = Set<String>()
        for manifest in manifests {
            for entry in manifest.entries.values {
                candidates.insert(entry.relativePath)
                // Versiones anteriores guardadas al lado ("nombre (v AAAA-MM-DD).ext").
                let directory = (entry.relativePath as NSString).deletingLastPathComponent
                if let siblings = try? FileManager.default.contentsOfDirectory(
                    atPath: try SafePath.resolve(directory, under: oldRoot).path)
                {
                    let stem = ((entry.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
                    for sibling in siblings where sibling.hasPrefix(stem + " (v ") {
                        candidates.insert(SafePath.join([directory, sibling]))
                    }
                }
            }
            // `_enlaces.md` de cada curso: el primer componente de cualquier entrada es la carpeta del curso.
            if let any = manifest.entries.values.first {
                let course = String(any.relativePath.split(separator: "/").first ?? "")
                let links = SafePath.join([course] + Config.subfolderComponents(oldSubfolder) + ["_enlaces.md"])
                candidates.insert(links)
            }
        }

        var result = Plan(moves: [], missing: [], conflicts: [])
        var targets = Set<String>()
        for path in candidates.sorted() {
            let source = try SafePath.resolve(path, under: oldRoot)
            guard FileManager.default.fileExists(atPath: source.path) else {
                if !path.hasSuffix("_enlaces.md") { result.missing.append(path) }
                continue
            }
            let newPath = newRelativePath(path, oldSubfolder: oldSubfolder, newSubfolder: newSubfolder)
            let target = try SafePath.resolve(newPath, under: newRoot)
            if source.standardizedFileURL == target.standardizedFileURL { continue }
            if FileManager.default.fileExists(atPath: target.path) || !targets.insert(newPath.lowercased()).inserted {
                result.conflicts.append(newPath)
                continue
            }
            result.moves.append(Move(from: path, to: newPath))
        }
        return result
    }

    /// Ejecuta el plan. Si hay conflictos no mueve nada. Devuelve los manifiestos actualizados.
    public static func execute(
        _ plan: Plan,
        manifests: [Manifest],
        from oldRoot: URL,
        to newRoot: URL,
        oldSubfolder: String?,
        newSubfolder: String?
    ) throws -> [Manifest] {
        guard plan.conflicts.isEmpty else {
            throw CampusSyncError.config("hay \(plan.conflicts.count) archivos que ya existen en el destino; no se movió nada.")
        }
        for move in plan.moves {
            let source = try SafePath.resolve(move.from, under: oldRoot)
            let target = try SafePath.resolve(move.to, under: newRoot)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: target)
        }
        return manifests.map { manifest in
            var updated = manifest
            for (key, entry) in manifest.entries {
                updated.entries[key]?.relativePath = newRelativePath(
                    entry.relativePath, oldSubfolder: oldSubfolder, newSubfolder: newSubfolder)
            }
            return updated
        }
    }

    /// Borra las carpetas que quedaron vacías **solo** entre las que contenían archivos movidos (y sus
    /// padres hasta `root`, sin incluirlo). Nunca toca otras carpetas del usuario. Una carpeta que solo
    /// tiene `.DS_Store` cuenta como vacía.
    public static func removeEmptyDirectories(after moves: [Move], under root: URL) {
        let fileManager = FileManager.default
        var directories = Set<String>()
        for move in moves {
            var components = move.from.split(separator: "/").map(String.init).dropLast()
            while !components.isEmpty {
                directories.insert(SafePath.join(Array(components)))
                components = components.dropLast()
            }
        }
        for relative in directories.sorted(by: { $0.count > $1.count }) {
            guard let directory = try? SafePath.resolve(relative, under: root) else { continue }
            let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) {
                try? fileManager.removeItem(at: directory)
            }
        }
    }
}
