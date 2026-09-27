import Foundation

public struct Modification: Sendable, Equatable {
    public let remote: RemoteFile
    public let previous: ManifestEntry
}

public struct SyncPlan: Sendable, Equatable {
    /// Nunca descargados.
    public var new: [RemoteFile] = []
    /// Cambiaron en el campus (fecha o tamaño) desde la última descarga.
    public var modified: [Modification] = []
    /// Estaban descargados pero el archivo local ya no existe.
    public var missingLocally: [RemoteFile] = []
    /// Desaparecieron del campus en esta corrida.
    public var retired: [ManifestEntry] = []
    public var unchanged: [RemoteFile] = []

    public var pendingDownloads: Int { new.count + modified.count + missingLocally.count }
    public var hasChanges: Bool { pendingDownloads > 0 || !retired.isEmpty }
}

/// Lógica pura: compara lo que hay en el campus con el manifiesto local.
public enum SyncPlanner {
    public static func plan(
        remote: [RemoteFile],
        manifest: Manifest?,
        fileExists: (String) -> Bool
    ) -> SyncPlan {
        let entries = manifest?.entries ?? [:]
        var plan = SyncPlan()

        // Rutas ocupadas: las ya asignadas (incluso retiradas, cuyo archivo sigue en disco).
        var usedPaths = Set(entries.values.map { $0.relativePath.lowercased() })
        var seenKeys = Set<String>()

        for var file in remote {
            guard seenKeys.insert(file.key).inserted else { continue }

            if let previous = entries[file.key] {
                // La ruta de un archivo conocido no cambia aunque renombren la sección.
                file.relativePath = previous.relativePath
                if previous.timemodified != file.timemodified || previous.filesize != file.filesize {
                    plan.modified.append(Modification(remote: file, previous: previous))
                } else if !fileExists(previous.relativePath) {
                    plan.missingLocally.append(file)
                } else {
                    plan.unchanged.append(file)
                }
            } else {
                file.relativePath = uniquePath(file.relativePath, moduleTag: moduleTag(of: file.key), used: usedPaths)
                usedPaths.insert(file.relativePath.lowercased())
                plan.new.append(file)
            }
        }

        let remoteKeys = Set(remote.map(\.key))
        plan.retired = entries.values
            .filter { !remoteKeys.contains($0.key) && $0.retiredAt == nil }
            .sorted { $0.relativePath < $1.relativePath }
        return plan
    }

    /// Dos archivos distintos del campus pueden terminar con el mismo nombre local
    /// (mismo nombre en la misma sección, o nombres que difieren solo en mayúsculas,
    /// que en macOS son el mismo archivo). Se desambigua con el id del módulo.
    static func uniquePath(_ path: String, moduleTag: String, used: Set<String>) -> String {
        guard used.contains(path.lowercased()) else { return path }
        let tagged = SafePath.insertSuffix(" (\(moduleTag))", into: path)
        if !used.contains(tagged.lowercased()) { return tagged }
        var counter = 2
        while true {
            let candidate = SafePath.insertSuffix(" (\(moduleTag)-\(counter))", into: path)
            if !used.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    private static func moduleTag(of key: String) -> String {
        String(key.prefix { $0 != "|" })
    }
}
