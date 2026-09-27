import Foundation
import Synchronization
import Testing

@testable import CampusSyncCore

/// Guarda los pedidos que hace el cliente para poder inspeccionarlos.
final class RequestRecorder: Sendable {
    private let storage = Mutex<[URLRequest]>([])
    var requests: [URLRequest] { storage.withLock { $0 } }
    func record(_ request: URLRequest) { storage.withLock { $0.append(request) } }
}

func fakeTransport(json: String, status: Int = 200, recorder: RequestRecorder? = nil) -> HTTPTransport {
    { request in
        recorder?.record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
}

let campus = URL(string: "https://campus.example.edu")!
let token = "0123456789abcdef0123456789abcdef"

@Suite("MoodleClient")
struct MoodleClientTests {
    @Test("Rechaza un campus sin https")
    func requiresHTTPS() {
        #expect(throws: CampusSyncError.insecureURL("http://campus.example.edu")) {
            try MoodleClient(baseURL: URL(string: "http://campus.example.edu")!, token: token)
        }
    }

    @Test("El token viaja en el cuerpo del POST, no en la URL")
    func tokenInBody() async throws {
        let recorder = RequestRecorder()
        let client = try MoodleClient(
            baseURL: campus, token: token,
            send: fakeTransport(json: #"{"userid": 7, "sitename": "Campus"}"#, recorder: recorder))
        let site = try await client.siteInfo()
        #expect(site.userid == 7)

        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://campus.example.edu/webservice/rest/server.php")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("wstoken=\(token)"))
        #expect(body.contains("wsfunction=core_webservice_get_site_info"))
    }

    @Test("invalidtoken se traduce a un error claro")
    func invalidToken() async throws {
        let client = try MoodleClient(
            baseURL: campus, token: token,
            send: fakeTransport(
                json: #"{"exception":"moodle_exception","errorcode":"invalidtoken","message":"Token no válido"}"#))
        await #expect(throws: CampusSyncError.invalidToken) { try await client.siteInfo() }
    }

    @Test("Otros errores de Moodle conservan código y mensaje")
    func moodleError() async throws {
        let client = try MoodleClient(
            baseURL: campus, token: token,
            send: fakeTransport(
                json: #"{"exception":"required_capability_exception","errorcode":"nopermissions","message":"Sin permiso"}"#))
        await #expect(throws: CampusSyncError.moodle(code: "nopermissions", message: "Sin permiso")) {
            try await client.contents(courseID: 1)
        }
    }

    @Test("HTTP distinto de 2xx es un error")
    func httpError() async throws {
        let client = try MoodleClient(baseURL: campus, token: token, send: fakeTransport(json: "", status: 503))
        await #expect(throws: CampusSyncError.http(status: 503)) { try await client.siteInfo() }
    }

    @Test("Login: usuario y contraseña en el cuerpo, con el servicio de la app móvil")
    func loginRequest() async throws {
        let recorder = RequestRecorder()
        let received = try await MoodleClient.requestToken(
            baseURL: campus, username: "ana", password: "p&ss=word?",
            send: fakeTransport(json: #"{"token":"\#(token)","privatetoken":null}"#, recorder: recorder))
        #expect(received == token)

        let request = try #require(recorder.requests.first)
        #expect(request.url?.query == nil)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "username=ana&password=p%26ss%3Dword%3F&service=moodle_mobile_app")
    }

    @Test("Login fallido")
    func loginFailure() async {
        await #expect(throws: CampusSyncError.invalidLogin("Invalid login, please try again")) {
            try await MoodleClient.requestToken(
                baseURL: campus, username: "ana", password: "mal",
                send: fakeTransport(json: #"{"error":"Invalid login, please try again","errorcode":"invalidlogin"}"#))
        }
    }

    @Test("URL de descarga: pasa por webservice/pluginfile y agrega el token")
    func downloadURL() throws {
        let client = try MoodleClient(baseURL: campus, token: token)
        let url = try client.downloadURL(
            for: "https://campus.example.edu/pluginfile.php/5/mod_resource/content/1/Apunte%20(1).pdf?forcedownload=1")
        #expect(
            url.absoluteString
                == "https://campus.example.edu/webservice/pluginfile.php/5/mod_resource/content/1/Apunte%20(1).pdf?forcedownload=1&token=\(token)"
        )
    }

    @Test("Nunca manda el token a otro servidor")
    func refusesForeignHost() throws {
        let client = try MoodleClient(baseURL: campus, token: token)
        #expect(throws: CampusSyncError.foreignHost("evil.example.com")) {
            try client.downloadURL(for: "https://evil.example.com/webservice/pluginfile.php/1/x.pdf")
        }
        #expect(throws: CampusSyncError.self) {
            try client.downloadURL(for: "http://campus.example.edu/webservice/pluginfile.php/1/x.pdf")
        }
    }
}

@Suite("Redactor")
struct RedactorTests {
    @Test("Tapa el token en URLs, JSON y como texto suelto")
    func redacts() {
        let redactor = Redactor(secrets: [token])
        let text = """
            GET https://campus.example.edu/webservice/pluginfile.php/1/a.pdf?forcedownload=1&token=\(token)
            {"token":"\(token)","privatetoken":"otro-secreto-largo"} wstoken=abc password=hunter22 suelto \(token)
            """
        let output = redactor.redact(text)
        #expect(!output.contains(token))
        #expect(!output.contains("otro-secreto-largo"))
        #expect(!output.contains("hunter22"))
        #expect(!output.contains("wstoken=abc"))
        #expect(output.contains("forcedownload=1"))
    }
}

@Suite("Reporter")
struct ReporterTests {
    @Test("Solo http/https se vuelven enlaces clickeables")
    func linkSchemes() {
        #expect(Reporter.safeLinkURL("javascript:alert(1)") == nil)
        #expect(Reporter.safeLinkURL("file:///etc/passwd") == nil)
        #expect(Reporter.safeLinkURL("https://youtu.be/x(1)") == "https://youtu.be/x%281%29")
    }

    @Test("Los nombres del campus no pueden romper el Markdown")
    func escapesMarkdown() {
        let links = [RemoteLink(sectionName: "S\n# Falso título", name: "[click](https://evil)", url: "https://ok.example")]
        let markdown = Reporter.linksMarkdown(courseTitle: "Materia", links: links)
        #expect(markdown.contains("- [\\[click\\](https://evil)](https://ok.example)"))
        #expect(!markdown.contains("\n# Falso"))
    }
}
