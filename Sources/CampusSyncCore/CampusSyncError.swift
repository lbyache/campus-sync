import Foundation
import Security

public enum CampusSyncError: Error, Equatable, CustomStringConvertible {
    case insecureURL(String)
    case invalidLogin(String)
    case invalidToken
    case notLoggedIn
    case moodle(code: String, message: String)
    case http(status: Int)
    case network(String)
    case unexpectedResponse(String)
    case foreignHost(String)
    case unsafePath(String)
    case fileTooLarge(name: String, bytes: Int)
    case keychain(OSStatus)
    case config(String)

    public var description: String {
        switch self {
        case .insecureURL(let url):
            "El campus tiene que usar https:// (recibí \(url))."
        case .invalidLogin(let message):
            "Usuario o contraseña incorrectos: \(message)"
        case .invalidToken:
            "El token del campus venció o fue revocado. Corré `campus-sync login`."
        case .notLoggedIn:
            "No hay sesión guardada. Corré `campus-sync login`."
        case .moodle(let code, let message):
            "Moodle respondió un error (\(code)): \(message)"
        case .http(let status):
            "El campus respondió HTTP \(status)."
        case .network(let message):
            "Error de red: \(message)"
        case .unexpectedResponse(let context):
            "Respuesta inesperada del campus en \(context)."
        case .foreignHost(let host):
            "Un archivo apunta a otro servidor (\(host)); no se le manda el token."
        case .unsafePath(let path):
            "Ruta rechazada por salir de la carpeta destino: \(path)"
        case .fileTooLarge(let name, let bytes):
            "\(name) pesa \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) y supera el límite configurado."
        case .keychain(let status) where status == errSecUserCanceled || status == errSecInteractionNotAllowed:
            "macOS no dejó leer el token del Llavero sin preguntar (OSStatus \(status)). "
                + "Corré `campus-sync logout` y `campus-sync login` en la Terminal para que el programa actual quede autorizado."
        case .keychain(let status):
            "Error del Llavero (OSStatus \(status))."
        case .config(let message):
            "Configuración: \(message)"
        }
    }
}
