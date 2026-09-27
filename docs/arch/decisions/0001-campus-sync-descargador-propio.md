# 0001. campus-sync: descargador propio de Moodle, CLI en Swift sin dependencias

## Estado
Accepted (2026-09-26). En una primera versión se evaluó Node + TypeScript. Se cambió a Swift porque el
proyecto exige cero dependencias, y sin el paquete `typescript` Node no verifica los tipos.

## Contexto

El material de una cursada suele estar repartido entre el campus Moodle, alguna nube y carpetas
locales. El campus hay que recorrerlo a mano, curso por curso, y nunca queda claro si está todo
bajado ni qué es nuevo.

`campus-sync` resuelve tres cosas:
1. **Espejar el campus** en una carpeta local (por ejemplo, dentro de Google Drive para escritorio,
   para verla también desde el teléfono).
2. **Detectar novedades**: qué se subió, qué cambió y qué retiraron.
3. Responder **"¿tengo todo?"** sin descargar nada.

**Restricciones del proyecto:**
- La herramienta maneja una credencial con acceso a toda la vida académica de quien la usa. Por eso
  **todo el código que toca esa credencial tiene que ser propio y auditable**, y no se ejecuta código
  de terceros con ella.
- **Cero dependencias**, ni siquiera de desarrollo: menos superficie de cadena de suministro y un
  proyecto que se puede leer entero.
- Corre en una sola Mac, sin servidor, periódicamente, para una sola persona.
- El servidor Moodle es de terceros (la institución): hay que tratarlo con cuidado y **no confiar**
  en los nombres de archivo que devuelve.

**Acceso a Moodle:** API oficial de Web Services, la misma que usa la app móvil oficial. No se hace
scraping. La institución tiene que tener habilitado el servicio móvil; se puede comprobar sin
credenciales con `tool_mobile_get_public_config` (`enablewebservices` y `enablemobilewebservice` en `1`).

| Paso | Endpoint / función |
|---|---|
| Token | `POST /login/token.php` con `service=moodle_mobile_app` (login con usuario y contraseña del campus) |
| Usuario | `core_webservice_get_site_info` |
| Cursos | `core_enrol_get_users_courses` |
| Contenido | `core_course_get_contents` → secciones → módulos → `contents[]` (`fileurl`, `filename`, `filepath`, `filesize`, `timemodified`) |
| Descarga | `fileurl` (`/webservice/pluginfile.php/...`) + parámetro `token` |

Si la institución usa SSO, `login/token.php` no acepta usuario y contraseña. En ese caso el token se
copia a mano desde *Preferencias › Claves de seguridad* y se usa `campus-sync login --token`.

## Opciones consideradas

1. **A. Moodle-DL (existente, Python).** Muy completo, pero es código de terceros con un árbol de
   dependencias de pip considerable. Choca con la primera restricción.
2. **B. Node 26 + TypeScript sin dependencias.** Se itera rápido, pero sin `typescript` instalado los
   tipos no se verifican nunca.
3. **C. Python, solo biblioteca estándar.** Viable, sin verificación de tipos y con peor integración
   con el Llavero.
4. **D. CLI en Swift (SwiftPM), solo frameworks de Apple.** El compilador verifica todo sin agregar
   nada y el Llavero es nativo.

## Matriz de decisión

Puntaje de 1 a 5; total ponderado sobre 100.

| Criterio | Peso | A. Moodle-DL | B. Node/TS | C. Python | D. Swift |
|---|---:|---:|---:|---:|---:|
| Confianza en el código que maneja la credencial | 25 | 2 | 5 | 5 | 5 |
| Dependencias de terceros | 15 | 1 | 5 | 4 | 5 |
| Corrección verificada (tipos, compilador) | 15 | 3 | 2 | 2 | 5 |
| Esfuerzo hasta el MVP | 15 | 5 | 4 | 3 | 3 |
| Mantenibilidad y reutilización (p. ej., una app con interfaz) | 15 | 2 | 3 | 2 | 5 |
| Integración con macOS (Llavero, launchd, avisos) | 15 | 3 | 3 | 3 | 5 |
| **Total** | 100 | **55** | **76** | **70** | **94** |

## Decisión

Elegimos la **opción D**: `campus-sync`, un ejecutable de SwiftPM que usa solo frameworks del sistema.

**Stack:**

| Pieza | Elección | Por qué |
|---|---|---|
| Lenguaje | Swift 6 (tools 6.1+), modo de lenguaje 6 | Concurrencia estricta: los errores de datos compartidos aparecen al compilar. |
| Paquete | SwiftPM: `CampusSyncCore` (librería) + `campus-sync` (ejecutable) | La lógica vive en la librería y se testea; el ejecutable solo lee argumentos y hace entrada/salida. Deja abierta la puerta a otras interfaces. |
| Argumentos | Parser propio mínimo sobre `CommandLine.arguments` | Por la regla de cero dependencias no se usa `swift-argument-parser`; son pocos comandos. |
| Red | `URLSession` async/await, sesión efímera | Del sistema. Sin caché ni cookies en disco. |
| JSON | `Codable`, con opcionales en todo lo que Moodle puede omitir | Si Moodle cambia un campo no crítico, el parseo no se rompe. |
| Secretos | Security.framework (`kSecClassGenericPassword`) | Llavero nativo, sin procesos externos. |
| Hash | CryptoKit `SHA256` | Del sistema. |
| Tests | Swift Testing | Incluido en el toolchain. |
| Agenda | `launchd` (`~/Library/LaunchAgents`) | Nativo. Corre la tarea perdida cuando la Mac se despierta. |
| Avisos | `osascript` con argumentos + `NOVEDADES.md` | Un ejecutable suelto no puede usar `UserNotifications` (necesita un bundle de app). |
| Lint / formato | `swift format` (incluido en el toolchain) | Sin dependencias nuevas. |

**Módulos de `CampusSyncCore`:** la lógica pura va separada de la entrada/salida para poder testearla.

```
MoodleClient     cliente de Web Services: arma pedidos, decodifica y convierte errores de Moodle en errores tipados
Models           structs Codable de la API
RemoteCatalog    PURO: contenidos del curso → archivos y enlaces, con su ruta local
SyncPlanner      PURO: (remoto, manifiesto) → plan {nuevos, modificados, faltantes, retirados, sin cambios}
SafePath         PURO: sanea nombres y garantiza que la ruta quede dentro del destino
ManifestStore    manifest.json por curso; escritura atómica
SyncEngine       orquesta: descargas secuenciales con pausa, archivo temporal + reemplazo, versión anterior
Keychain         guarda y lee el token
Reporter         NOVEDADES.md, _enlaces.md, resumen de status, aviso de macOS
Redactor         PURO: quita token=/wstoken= de cualquier texto antes de mostrarlo
Config           ~/.config/campus-sync/config.json (URL, destino, cursos, alias); sin secretos
```

**Reglas de comportamiento:**
- Nunca borra nada local. Lo que el campus retira se reporta como tal.
- Cuando un archivo se modifica, la versión anterior se conserva como `nombre (v AAAA-MM-DD).ext`.
- Descargas secuenciales con pausa entre pedidos.
- Los módulos `url` van a `_enlaces.md`.
- Solo acepta un campus `https://` y una carpeta destino absoluta.

## Consecuencias

- **Positivas:** todo el código que toca la credencial es propio y legible. No hay cadena de
  suministro. Hay seguridad de tipos completa sin costo. `CampusSyncCore` se puede reutilizar desde
  otras herramientas (por ejemplo, un planificador de estudio) como fuente de "material nuevo".
- **Negativas / trade-offs:**
  - Solo funciona en macOS.
  - Cada cambio necesita compilar, y los `Codable` son más verbosos que el JSON dinámico.
  - El MVP cubre menos que Moodle-DL: no incluye foros, videos embebidos ni cuestionarios.
  - Si una actualización de Moodle cambia la API, hay que ajustar el cliente.

**Riesgos y mitigaciones:**

| Riesgo | Mitigación |
|---|---|
| La institución deshabilitó Web Services o el servicio móvil | Se detecta con la consulta pública antes del primer login. No hay alternativa sin scraping, que queda fuera de alcance. |
| Path traversal en `filename`/`filepath` (CWE-22) | `SafePath` + verificación de que la ruta final quede dentro del destino, también frente a enlaces simbólicos. Tests con `../`, rutas absolutas, caracteres de control y caracteres de dirección de texto. |
| Token filtrado en logs (va en la query string de las descargas) | Toda salida pasa por `Redactor`. Hay tests. |
| Token enviado a otro servidor | El token solo se agrega a `fileurl` del mismo host y puerto que el campus, y solo por `https`. |
| Token vencido o revocado | Error claro que indica correr `campus-sync login`. Sin reintentos en loop. |
| Carpeta en la nube sincronizando mientras se escribe | Escritura atómica. El destino es configurable. |
| Carga sobre el servidor de la institución | Secuencial, solo lo que cambió, con pausa entre pedidos, una vez por semana (o por día, a elección). |
| Pérdida de acceso al Llavero después de recompilar | El instalador firma con un certificado Apple Development si hay uno, lo que mantiene la identidad entre compilaciones. Con firma ad hoc, `logout` + `login` rehace el permiso. |
| Falla silenciosa del sync programado | Sin terminal, los errores llevan hora en el log y disparan un aviso de macOS. |

## Cumplimiento

- **Seguridad:** OWASP ASVS V8 (token solo en el Llavero, nunca en disco ni en logs), V12 (CWE-22),
  V9 (solo HTTPS). La contraseña se lee sin eco, se usa una vez y se descarta. El token es el de la
  app móvil: no se piden privilegios extra.
- **Calidad:** Swift Testing sobre `SafePath`, `RemoteCatalog`, `SyncPlanner`, `Redactor`, el escape
  de `Reporter`, el cliente con transporte simulado y un sync de punta a punta con un campus falso.
  Objetivo: más de 70 % de cobertura en el core.
- **Normativo:** la herramienta solo baja material al que quien la usa ya tiene acceso con sus propias
  credenciales, para uso personal. El material pertenece a sus autores y no se redistribuye. Los
  fixtures de test son ficticios.

## Plan en fases

| Fase | Alcance |
|---|---|
| 1. MVP | `login`, `cursos`, `status`, `sync`, `logout`; recursos, carpetas y páginas; `_enlaces.md`; manifiesto; `NOVEDADES.md`; aviso; `launchd`. |
| 2. | Adjuntos y fechas de entrega de tareas (`mod_assign_get_assignments`) y foro de novedades. |

## Referencias
- Moodle Web Services API: https://docs.moodle.org/dev/Web_service_API_functions
- Moodle, cliente de web services: https://docs.moodle.org/dev/Creating_a_web_service_client
- Swift Testing: https://developer.apple.com/documentation/testing
- Keychain Services: https://developer.apple.com/documentation/security/keychain_services
- CWE-22 Path Traversal: https://cwe.mitre.org/data/definitions/22.html
- Alternativa descartada: https://github.com/C0D3D3V/Moodle-DL
