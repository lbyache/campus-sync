import Foundation

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
public typealias DownloadTransport = @Sendable (URLRequest) async throws -> (URL, URLResponse)

/// Cliente mínimo de la API oficial de Web Services de Moodle (la que usa la app móvil).
///
/// Decisiones de seguridad:
/// - Solo `https`.
/// - El token va en el cuerpo del POST en las llamadas a funciones, nunca en la URL.
/// - En las descargas el token solo se agrega si el archivo está en el mismo host que el campus.
/// - Los errores de red se reempaquetan sin la URL (que podría llevar el token).
public struct MoodleClient: Sendable {
    public let baseURL: URL
    private let token: String
    private let send: HTTPTransport
    private let download: DownloadTransport

    public init(
        baseURL: URL,
        token: String,
        send: @escaping HTTPTransport = MoodleClient.urlSessionSend,
        download: @escaping DownloadTransport = MoodleClient.urlSessionDownload
    ) throws {
        try Self.requireHTTPS(baseURL)
        self.baseURL = baseURL
        self.token = token
        self.send = send
        self.download = download
    }

    // MARK: - Transporte por defecto

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral  // sin caché ni cookies en disco
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.httpAdditionalHeaders = ["User-Agent": "campus-sync/0.1 (+uso personal)"]
        return URLSession(configuration: configuration)
    }()

    public static let urlSessionSend: HTTPTransport = { request in
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw CampusSyncError.network(networkDescription(error))
        }
    }

    public static let urlSessionDownload: DownloadTransport = { request in
        do {
            return try await session.download(for: request)
        } catch let error as URLError {
            throw CampusSyncError.network(networkDescription(error))
        }
    }

    private static func networkDescription(_ error: URLError) -> String {
        // `localizedDescription` no incluye la URL; el userInfo sí, por eso no se usa.
        "\(error.localizedDescription) (código \(error.code.rawValue))"
    }

    // MARK: - Login

    /// Canjea usuario y contraseña por un token. La contraseña va solo en el cuerpo del POST
    /// y no se guarda en ningún lado.
    public static func requestToken(
        baseURL: URL,
        username: String,
        password: String,
        send: HTTPTransport = MoodleClient.urlSessionSend
    ) async throws -> String {
        try requireHTTPS(baseURL)
        var request = URLRequest(url: baseURL.appending(path: "login/token.php"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode([
            ("username", username),
            ("password", password),
            ("service", "moodle_mobile_app"),
        ])

        let (data, response) = try await send(request)
        try checkHTTP(response)

        struct TokenResponse: Decodable {
            let token: String?
            let error: String?
            let errorcode: String?
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw CampusSyncError.unexpectedResponse("login/token.php")
        }
        if let token = decoded.token, !token.isEmpty {
            return token
        }
        throw CampusSyncError.invalidLogin(decoded.error ?? decoded.errorcode ?? "sin detalle")
    }

    // MARK: - Funciones de la API

    public func siteInfo() async throws -> SiteInfo {
        try await call("core_webservice_get_site_info", as: SiteInfo.self)
    }

    public func courses(userID: Int) async throws -> [Course] {
        try await call("core_enrol_get_users_courses", [("userid", String(userID))], as: [Course].self)
    }

    public func contents(courseID: Int) async throws -> [CourseSection] {
        try await call("core_course_get_contents", [("courseid", String(courseID))], as: [CourseSection].self)
    }

    func call<T: Decodable>(_ function: String, _ parameters: [(String, String)] = [], as type: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: "webservice/rest/server.php"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(
            [("wstoken", token), ("wsfunction", function), ("moodlewsrestformat", "json")] + parameters
        )

        let (data, response) = try await send(request)
        try Self.checkHTTP(response)
        try Self.throwIfMoodleError(data)

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CampusSyncError.unexpectedResponse(function)
        }
    }

    // MARK: - Descargas

    /// URL de descarga con el token, o error si el archivo no está en el host del campus.
    public func downloadURL(for fileURL: String) throws -> URL {
        guard var components = URLComponents(string: fileURL), let host = components.host else {
            throw CampusSyncError.unexpectedResponse("fileurl")
        }
        guard components.scheme?.lowercased() == "https",
            host.lowercased() == baseURL.host()?.lowercased(),
            components.port == baseURL.port
        else {
            throw CampusSyncError.foreignHost(host)
        }
        // Con token, Moodle solo sirve archivos por el endpoint de web services.
        if !components.percentEncodedPath.contains("/webservice/pluginfile.php/"),
            let range = components.percentEncodedPath.range(of: "/pluginfile.php/")
        {
            components.percentEncodedPath.replaceSubrange(range, with: "/webservice/pluginfile.php/")
        }
        var items = (components.queryItems ?? []).filter { $0.name.lowercased() != "token" }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        guard let url = components.url else {
            throw CampusSyncError.unexpectedResponse("fileurl")
        }
        return url
    }

    /// Descarga a un archivo temporal. Quien llama lo mueve a su destino final.
    public func downloadFile(_ fileURL: String) async throws -> URL {
        let request = URLRequest(url: try downloadURL(for: fileURL))
        let (temporaryURL, response) = try await download(request)
        try Self.checkHTTP(response)

        // Si el token es inválido, Moodle devuelve 200 con un JSON de error en lugar del archivo.
        if let http = response as? HTTPURLResponse,
            http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true,
            let size = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 * 1024,
            let data = try? Data(contentsOf: temporaryURL)
        {
            do {
                try Self.throwIfMoodleError(data)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
        return temporaryURL
    }

    // MARK: - Utilidades

    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host() != nil else {
            throw CampusSyncError.insecureURL(url.absoluteString)
        }
    }

    static func checkHTTP(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CampusSyncError.http(status: http.statusCode)
        }
    }

    static func throwIfMoodleError(_ data: Data) throws {
        guard let payload = try? JSONDecoder().decode(MoodleErrorPayload.self, from: data), payload.isError else {
            return
        }
        let code = payload.errorcode ?? payload.exception ?? "desconocido"
        if code == "invalidtoken" || code == "invalidtokenerror" {
            throw CampusSyncError.invalidToken
        }
        throw CampusSyncError.moodle(code: code, message: payload.message ?? payload.error ?? "")
    }
}

enum FormEncoding {
    private static let unreserved = CharacterSet(
        charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ pairs: [(String, String)]) -> Data {
        let body =
            pairs
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
