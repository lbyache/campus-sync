import Foundation

/// Convierte nombres que vienen del servidor en rutas locales seguras (CWE-22).
///
/// Los nombres de archivo y carpeta los elige quien sube el material al campus,
/// así que se tratan como no confiables: nada de `..`, rutas absolutas,
/// caracteres de control ni caracteres invisibles de dirección de texto.
public enum SafePath {
    public static let maxComponentBytes = 200

    /// Un solo componente de ruta (sin `/`), apto para el sistema de archivos de macOS.
    public static func sanitizeComponent(_ raw: String) -> String {
        let normalized = raw.precomposedStringWithCanonicalMapping
        let visible = normalized.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                false
            default:
                true
            }
        }
        var component = String(String.UnicodeScalarView(visible))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)

        // Sin punto inicial: evita `..`, `.` y archivos ocultos.
        while component.hasPrefix(".") {
            component.removeFirst()
            component = component.trimmingCharacters(in: .whitespaces)
        }
        if component.isEmpty {
            return "_"
        }
        return truncate(component, maxBytes: maxComponentBytes)
    }

    /// `filepath` de Moodle (`/`, `/sub/carpeta/`) → componentes seguros.
    public static func sanitizeDirectory(_ filepath: String?) -> [String] {
        (filepath ?? "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .map(sanitizeComponent)
    }

    public static func join(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    /// Resuelve una ruta relativa dentro de `base` y verifica que no escape de ella,
    /// ni por `..` ni por un enlace simbólico que ya exista en el camino.
    public static func resolve(_ relativePath: String, under base: URL) throws -> URL {
        let root = base.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appending(path: relativePath).standardizedFileURL
        guard isInside(candidate, root) else {
            throw CampusSyncError.unsafePath(relativePath)
        }
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard resolvedParent.path == root.path || isInside(resolvedParent, root) else {
            throw CampusSyncError.unsafePath(relativePath)
        }
        return candidate
    }

    /// `apunte.pdf` → `apunte (v 2026-09-01).pdf`
    public static func versionedName(_ relativePath: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return insertSuffix(" (v \(formatter.string(from: date)))", into: relativePath)
    }

    /// Inserta un sufijo antes de la extensión del último componente.
    public static func insertSuffix(_ suffix: String, into relativePath: String) -> String {
        var components = relativePath.split(separator: "/").map(String.init)
        guard let last = components.popLast() else { return suffix }
        let (stem, ext) = splitExtension(last)
        components.append(stem + suffix + ext)
        return join(components)
    }

    // MARK: - Privado

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        let ext = String(name[dot...])
        guard ext.count <= 10 else { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    private static func truncate(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let (stem, ext) = splitExtension(name)
        var shortened = stem
        while !shortened.isEmpty, shortened.utf8.count + ext.utf8.count > maxBytes {
            shortened.removeLast()
        }
        return shortened + ext
    }
}
