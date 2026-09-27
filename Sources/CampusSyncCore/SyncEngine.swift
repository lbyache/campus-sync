import CryptoKit
import Foundation

public struct CourseResult: Sendable {
    public let course: Course
    public let folderName: String
    public var plan: SyncPlan
    public var linkCount: Int
    public var downloaded: [String] = []
    public var failures: [String] = []
    public var skippedTooLarge: [String] = []
}

public struct SyncReport: Sendable {
    public var siteName: String
    public var userName: String
    public var courses: [CourseResult] = []
    public let date: Date

    public var hasChanges: Bool { courses.contains { $0.plan.hasChanges } }
    public var failureCount: Int { courses.reduce(0) { $0 + $1.failures.count } }
}

public struct Logger: Sendable {
    let redactor: Redactor
    public init(redactor: Redactor) { self.redactor = redactor }

    public func info(_ message: String) {
        let line = "[\(Date().formatted(.iso8601))] \(redactor.redact(message))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Orquesta un sync: materias → contenidos → plan → descargas → manifiesto.
public struct SyncEngine: Sendable {
    let client: MoodleClient
    let config: Config
    let store: ManifestStore
    let log: Logger

    public init(client: MoodleClient, config: Config, store: ManifestStore = ManifestStore(), log: Logger) {
        self.client = client
        self.config = config
        self.store = store
        self.log = log
    }

    /// Con `apply == false` solo calcula el plan (comando `status`): no escribe nada.
    public func run(apply: Bool) async throws -> SyncReport {
        // Antes de tocar la red: sin carpeta destino no hay nada que comparar ni dónde escribir.
        let destination = try config.existingDestinationDirectory()
        let site = try await client.siteInfo()
        var report = SyncReport(
            siteName: site.sitename ?? "Campus",
            userName: site.fullname ?? site.username ?? "",
            date: Date()
        )
        let courses = try await client.courses(userID: site.userid)
            .filter { config.includes($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        for course in courses {
            try await Task.sleep(for: config.delay)
            let folder = config.folderName(for: course)
            let sections = try await client.contents(courseID: course.id)
            let coursePath = config.coursePath(for: course)
            let catalog = RemoteCatalog.build(coursePath: coursePath, sections: sections)
            var manifest = try store.load(courseID: course.id) ?? Manifest(courseID: course.id, courseTitle: course.title)

            let plan = SyncPlanner.plan(remote: catalog.files, manifest: manifest) { relativePath in
                guard let url = try? SafePath.resolve(relativePath, under: destination) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
            var result = CourseResult(course: course, folderName: folder, plan: plan, linkCount: catalog.links.count)

            if apply {
                try await applyPlan(
                    plan, links: catalog.links, coursePath: coursePath, title: folder, to: &manifest, result: &result)
            }
            report.courses.append(result)
        }
        return report
    }

    private func applyPlan(
        _ plan: SyncPlan,
        links: [RemoteLink],
        coursePath: [String],
        title: String,
        to manifest: inout Manifest,
        result: inout CourseResult
    ) async throws {
        let destination = try config.existingDestinationDirectory()
        let downloads: [(RemoteFile, ManifestEntry?)] =
            plan.new.map { ($0, nil) }
            + plan.modified.map { ($0.remote, $0.previous) }
            + plan.missingLocally.map { ($0, nil) }

        for (file, previous) in downloads {
            if file.filesize > config.maxFileBytes {
                result.skippedTooLarge.append(file.relativePath)
                log.info("Salteado por tamaño: \(file.relativePath)")
                continue
            }
            do {
                try await Task.sleep(for: config.delay)
                log.info("↓ \(file.relativePath)")
                let temporary = try await client.downloadFile(file.fileurl)
                let target = try SafePath.resolve(file.relativePath, under: destination)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

                if let previous, FileManager.default.fileExists(atPath: target.path) {
                    try keepPreviousVersion(of: target, relativePath: file.relativePath, previous: previous, under: destination)
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: target)
                }

                manifest.entries[file.key] = ManifestEntry(
                    remote: file, sha256: try Self.sha256(of: target), downloadedAt: Date())
                try store.save(manifest)  // después de cada archivo: un corte no pierde el progreso
                result.downloaded.append(file.relativePath)
            } catch CampusSyncError.invalidToken {
                throw CampusSyncError.invalidToken
            } catch {
                result.failures.append("\(file.relativePath): \(log.redactor.redact(String(describing: error)))")
                log.info("✗ \(file.relativePath): \(error)")
            }
        }

        let now = Date()
        for entry in plan.retired {
            manifest.entries[entry.key]?.retiredAt = now
        }
        try store.save(manifest)

        if !links.isEmpty {
            let linksFile = try SafePath.resolve(
                SafePath.join(coursePath + ["_enlaces.md"]), under: destination)
            try FileManager.default.createDirectory(at: linksFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Reporter.linksMarkdown(courseTitle: title, links: links).utf8).write(to: linksFile, options: .atomic)
        }
    }

    /// Guarda la versión anterior como `nombre (v AAAA-MM-DD).ext` antes de reemplazarla.
    private func keepPreviousVersion(of target: URL, relativePath: String, previous: ManifestEntry, under destination: URL) throws
    {
        let date = Date(timeIntervalSince1970: TimeInterval(previous.timemodified))
        var candidate = SafePath.versionedName(relativePath, date: date)
        var counter = 2
        while FileManager.default.fileExists(atPath: try SafePath.resolve(candidate, under: destination).path) {
            candidate = SafePath.insertSuffix(" \(counter)", into: SafePath.versionedName(relativePath, date: date))
            counter += 1
        }
        try FileManager.default.moveItem(at: target, to: try SafePath.resolve(candidate, under: destination))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
