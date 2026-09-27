import Foundation

/// Quita secretos de cualquier texto antes de mostrarlo o loguearlo.
///
/// El token de descarga viaja obligatoriamente en la query string de
/// `pluginfile.php`, así que cualquier URL o error de red puede contenerlo.
public struct Redactor: Sendable {
    public static let mask = "«REDACTED»"
    private let secrets: [String]

    public init(secrets: [String] = []) {
        // Un secreto muy corto taparía texto legítimo; los tokens de Moodle tienen 32 caracteres.
        self.secrets = secrets.filter { $0.count >= 8 }
    }

    public func redact(_ text: String) -> String {
        var output = text
        for secret in secrets {
            output = output.replacingOccurrences(of: secret, with: Self.mask)
        }
        output = output.replacing(#/(?i)\b(wstoken|privatetoken|token|password)=[^&\s"'<>]+/#) { match in
            "\(match.1)=\(Self.mask)"
        }
        output = output.replacing(#/(?i)"(wstoken|privatetoken|token|password)"\s*:\s*"[^"]*"/#) { match in
            "\"\(match.1)\":\"\(Self.mask)\""
        }
        return output
    }
}
