# AGENTS.md — campus-sync

CLI en Swift que espeja el campus Moodle en una carpeta local. Decisión y alternativas:
`docs/arch/decisions/0001-campus-sync-descargador-propio.md`.

## Commands

| Qué | Comando |
|---|---|
| Build (debug) | `swift build` |
| Build (release) | `swift build -c release` |
| Tests | `swift test` |
| Cobertura | `swift test --enable-code-coverage` y después `xcrun llvm-cov report .build/arm64-apple-macosx/debug/campus-syncPackageTests.xctest/Contents/MacOS/campus-syncPackageTests -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata --ignore-filename-regex='Tests/\|\.build/\|main\.swift'` |
| Lint | `swift format lint -r Sources Tests Package.swift` |
| Formato | `swift format -i -r Sources Tests Package.swift` |
| Run | `swift run campus-sync status` |
| Instalar + launchd | `scripts/install.sh` (se corre a mano: modifica LaunchAgents) |

## Architecture

- `CampusSyncCore` (librería) tiene toda la lógica. `campus-sync` (ejecutable, `main.swift`) solo
  parsea argumentos y hace entrada/salida interactiva.
- **Lógica pura y testeable:** `SafePath` (saneo de rutas, CWE-22), `RemoteCatalog` (contenidos de
  Moodle → archivos y enlaces), `SyncPlanner` (nuevos, modificados, faltantes y retirados), `Redactor`,
  y el escape de `Reporter`.
- **Entrada/salida:** `MoodleClient` (Web Services REST, transporte inyectable para tests),
  `SyncEngine` (orquesta y descarga), `ManifestStore` (JSON por curso en Application Support),
  `Keychain`, `Config`.
- La identidad de un archivo es `moduleID|filepath+filename`. Su ruta local se fija la primera vez
  y queda guardada en el manifiesto.

## Reglas del proyecto

- **Cero dependencias**, ni siquiera de desarrollo (regla del proyecto, ADR 0001). No sumar
  `swift-argument-parser` ni nada parecido.
- El token nunca va en logs, errores ni archivos. Todo texto que se imprime pasa por `Redactor`.
  Nunca se agrega el token a una URL de otro host.
- Todo nombre que venga del servidor pasa por `SafePath` antes de tocar el disco, y por
  `Reporter.inline`/`code` antes de ir a Markdown.
- Nunca se borran archivos del destino.
- Tests con Swift Testing. Fixtures sin datos reales (ni nombres de docentes ni ids reales).
- No correr `campus-sync login` desde un agente: la contraseña se escribe en una terminal interactiva, nunca por un agente ni un script.
