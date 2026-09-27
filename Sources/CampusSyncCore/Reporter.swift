import Foundation

/// Salidas legibles: `NOVEDADES.md`, `_enlaces.md`, resumen de `status` y aviso de macOS.
/// Todo texto que viene del campus se escapa antes de entrar en Markdown.
public enum Reporter {
    static let novedadesHeader = "# Novedades del campus\n\n"

    // MARK: - NOVEDADES.md

    /// Bloque de una corrida, o nil si no hubo cambios.
    public static func novedadesBlock(_ report: SyncReport) -> String? {
        let changed = report.courses.filter { !$0.downloaded.isEmpty || !$0.plan.retired.isEmpty || !$0.failures.isEmpty }
        guard !changed.isEmpty else { return nil }

        var lines = ["## \(timestamp(report.date)) — \(summary(report))", ""]
        for course in changed {
            lines.append("### \(inline(course.folderName))")
            let modifiedPaths = Set(course.plan.modified.map(\.remote.relativePath))
            for path in course.downloaded {
                lines.append("- \(modifiedPaths.contains(path) ? "Modificado" : "Nuevo"): `\(code(path))`")
            }
            for entry in course.plan.retired {
                lines.append("- Retirado del campus (se conserva la copia local): `\(code(entry.relativePath))`")
            }
            for failure in course.failures {
                lines.append("- No se pudo bajar: `\(code(failure))`")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Agrega la corrida arriba de todo, para que lo último quede primero.
    public static func prependNovedades(_ block: String, at url: URL) throws {
        var previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if previous.hasPrefix(novedadesHeader) {
            previous.removeFirst(novedadesHeader.count)
        }
        let content = novedadesHeader + block + "\n" + previous
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    // MARK: - _enlaces.md

    public static func linksMarkdown(courseTitle: String, links: [RemoteLink]) -> String {
        var lines = ["# Enlaces de \(inline(courseTitle))", "", "Generado por campus-sync. Se reescribe en cada sync.", ""]
        var currentSection: String?
        for link in links {
            if link.sectionName != currentSection {
                lines.append("")
                lines.append("## \(inline(link.sectionName))")
                currentSection = link.sectionName
            }
            if let url = safeLinkURL(link.url) {
                lines.append("- [\(inline(link.name))](\(url))")
            } else {
                // Esquemas raros (javascript:, file:, ...) se muestran como texto, no como enlace.
                lines.append("- \(inline(link.name)): `\(code(link.url))` (enlace no http/https, no se hace clickeable)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - status

    public static func statusText(_ report: SyncReport, listLimit: Int = 15) -> String {
        var lines = ["\(report.siteName) — \(report.userName)", ""]
        var totalPending = 0
        for course in report.courses {
            let plan = course.plan
            totalPending += plan.pendingDownloads
            let total = plan.unchanged.count + plan.pendingDownloads
            if !plan.hasChanges {
                lines.append("✔ \(course.folderName): \(total) archivos, todo al día")
                continue
            }
            lines.append("• \(course.folderName): \(total) archivos en el campus")
            var items: [String] = []
            items += plan.new.map { "  faltante   \($0.relativePath)" }
            items += plan.missingLocally.map { "  borrado localmente, se vuelve a bajar   \($0.relativePath)" }
            items += plan.modified.map { "  modificado \($0.remote.relativePath)" }
            items += plan.retired.map { "  retirado del campus   \($0.relativePath)" }
            lines += items.prefix(listLimit)
            if items.count > listLimit {
                lines.append("  … y \(items.count - listLimit) más")
            }
        }
        lines.append("")
        lines.append(
            totalPending == 0
                ? "Tenés todo el material del campus." : "Pendientes de bajar: \(totalPending). Corré `campus-sync sync`.")
        return lines.joined(separator: "\n")
    }

    public static func summary(_ report: SyncReport) -> String {
        let downloaded = report.courses.flatMap(\.downloaded)
        let modified = Set(report.courses.flatMap { $0.plan.modified.map(\.remote.relativePath) })
        let modifiedCount = downloaded.filter { modified.contains($0) }.count
        let retired = report.courses.reduce(0) { $0 + $1.plan.retired.count }
        var parts = ["\(downloaded.count - modifiedCount) nuevos", "\(modifiedCount) modificados"]
        if retired > 0 { parts.append("\(retired) retirados") }
        if report.failureCount > 0 { parts.append("\(report.failureCount) con error") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Aviso de macOS

    /// Los textos van como argumentos (`argv`), nunca interpolados en el AppleScript,
    /// para que un nombre de archivo no pueda inyectar código.
    public static func notify(title: String, message: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e", "end run",
            title, message,
        ]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Escape

    /// Texto plano en una línea de Markdown.
    static func inline(_ text: String) -> String {
        var output = oneLine(text)
        for character in ["\\", "`", "*", "_", "[", "]", "<", ">", "#", "|"] {
            output = output.replacingOccurrences(of: character, with: "\\" + character)
        }
        return output
    }

    /// Texto dentro de `código`: sin backticks ni saltos de línea.
    static func code(_ text: String) -> String {
        oneLine(text).replacingOccurrences(of: "`", with: "'")
    }

    static func safeLinkURL(_ raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.host() != nil
        else { return nil }
        return url.absoluteString
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
