# campus-sync

Espejo local de tu campus Moodle. Baja el material de todos tus cursos a una carpeta (por ejemplo,
dentro de Google Drive para escritorio, así también lo ves en el teléfono), detecta qué es nuevo, qué
cambió y qué retiraron, y responde **"¿tengo todo?"** sin descargar nada.

Está hecho en Swift, **sin dependencias**: usa solo frameworks de Apple, así que todo el código que
toca tu credencial se puede leer entero. El porqué está en
[docs/arch/decisions/0001](docs/arch/decisions/0001-campus-sync-descargador-propio.md).

> **English summary.** `campus-sync` is a zero-dependency macOS command-line tool that mirrors the
> files of your Moodle courses to a local folder using Moodle's official mobile Web Services API
> (the same one the official app uses; no scraping). It detects new, modified and removed files,
> keeps previous versions, never deletes anything locally, stores the token in the macOS Keychain,
> and can run weekly or daily via `launchd`. Requirements, a legal notice and a security policy are
> below and in [SECURITY.md](SECURITY.md). The documentation is in Spanish; issues and PRs in
> English are welcome.

## Requisitos

- **macOS 15 o posterior.** Usa el Llavero, `launchd` y los avisos de macOS; no funciona en Linux ni
  en Windows.
- **Swift 6.1 o posterior** (Xcode 16.3+ o las Command Line Tools equivalentes) para compilar.
- **Un campus Moodle con el servicio móvil habilitado.** Si podés entrar con la app oficial de
  Moodle en el teléfono, funciona. También se puede comprobar sin credenciales:

  ```bash
  curl -s -X POST 'https://TU-CAMPUS/lib/ajax/service-nologin.php?info=tool_mobile_get_public_config' -H 'Content-Type: application/json' -d '[{"index":0,"methodname":"tool_mobile_get_public_config","args":{}}]'
  ```

  Tienen que aparecer `"enablewebservices":1` y `"enablemobilewebservice":1`.

## Aviso legal

- **Proyecto no oficial.** No está afiliado a Moodle Pty Ltd ni a ninguna universidad o institución.
  "Moodle" es una marca de sus titulares.
- **Usás tus propias credenciales** y solo bajás material al que ya tenés acceso. Antes de usarlo,
  revisá los términos de uso de tu institución: algunas limitan el acceso automatizado.
- **El material de los cursos pertenece a sus autores.** `campus-sync` es para uso personal: no
  redistribuyas lo que descargues.
- Se ofrece "tal cual", sin garantías (ver [LICENSE](LICENSE)).

## Instalación y primer uso

```bash
scripts/install.sh              # compila, instala en ~/.local/bin y programa el sync semanal (domingo 10:00)
campus-sync login               # URL del campus, carpeta destino, usuario y contraseña
campus-sync cursos              # tus cursos con su id
campus-sync status              # ¿tengo todo? (no descarga)
campus-sync sync                # baja lo pendiente
```

- Si la institución usa SSO (entrar con Google o una cuenta institucional), `login` no acepta usuario
  y contraseña. Usá `campus-sync login --token` con el token de *Preferencias › Claves de seguridad*
  del campus.
- La carpeta de Google Drive para escritorio está en
  `~/Library/CloudStorage/GoogleDrive-<cuenta>/Mi unidad/…`. Poné ahí la ruta local, no el link web
  de la carpeta.
- Frecuencia: `scripts/install.sh --semanal` (domingo 10:00, por defecto) o `--diario` (08:00).
  Si la Mac está apagada o dormida a esa hora, corre cuando se despierta.
- ¿No querés ninguna corrida automática? Después de instalar, corré
  `launchctl bootout gui/$(id -u)/local.campus-sync` y usá `campus-sync sync` cuando quieras.

### El Llavero y el pedido de contraseña de la Mac

El token se guarda en el Llavero, y macOS recuerda qué programa lo guardó. Si el programa cambia (al
recompilarlo), macOS muestra una **ventana del sistema** pidiendo la contraseña de la Mac para dejarlo
leer ese elemento. Es legítima si:

- aparece como ventana de macOS, no como texto en la Terminal;
- nombra a `campus-sync` y al elemento `campus-sync (<host del campus>)`;
- sale justo cuando corriste un comando.

`campus-sync` nunca ve esa contraseña. Para que la ventana no vuelva a aparecer:

- **Con un certificado Apple Development** (lo tenés si alguna vez firmaste una app con Xcode),
  `install.sh` firma el binario con él. Así la identidad se mantiene entre versiones y el permiso se
  pide una sola vez.
- **Sin certificado**, el binario queda con firma ad hoc. Después de cada actualización, corré
  `campus-sync logout` y `campus-sync login` para que el binario nuevo vuelva a guardar el token.

Si una corrida automática no puede leer el Llavero (no hay nadie para responder la ventana), falla
con un aviso de macOS y un mensaje en el log que dice cómo arreglarlo. El permiso se revoca en
*Acceso a Llaveros* › buscar "campus-sync" › *Control de acceso*.

## Qué genera

```
<destino>/
├── NOVEDADES.md                    ← cada sync con cambios agrega un bloque arriba
└── Análisis II/                    ← nombre del curso, o su alias
    ├── _enlaces.md                 ← links externos del campus (YouTube, Drive…)
    ├── 00 General/Programa 2026.pdf
    └── 01 Unidad 1- Límites/
        └── Material de la unidad/  ← carpetas y páginas del campus conservan su estructura
            ├── apunte.pdf
            └── apunte (v 2026-09-01).pdf   ← versión anterior, si el archivo cambió
```

- **Nunca se borra nada local.** Lo que el campus retira se informa en `NOVEDADES.md` y se conserva.
- Si borrás un archivo del espejo, el próximo sync lo vuelve a bajar. El espejo es del campus: tus
  apuntes van en otra carpeta.
- Los manifiestos (qué se bajó y con qué fecha) viven en
  `~/Library/Application Support/campus-sync/manifests/`, fuera de la carpeta destino.

## Configuración

`~/.config/campus-sync/config.json` (la crea `login`; ver [config.example.json](config.example.json)):

| Campo | Para qué |
|---|---|
| `campusURL` | Solo `https://`. |
| `destination` | Carpeta espejo, ruta absoluta o con `~`. |
| `aliases` | `"id": "Nombre corto"` para la carpeta de cada curso. El id sale de `campus-sync cursos`. |
| `includeCourses` / `excludeCourses` | Listas de ids. |
| `maxFileSizeMB` | Por defecto, 500. Lo que supere el límite se saltea y queda informado. |
| `delayMilliseconds` | Pausa entre pedidos al servidor. Por defecto, 400. |

Un alias se lee cuando se descarga un archivo por primera vez. Los archivos ya bajados conservan su
ruta, para que el espejo no se reordene solo.

## Seguridad

- **Contraseña:** se escribe con el eco apagado y solo en una terminal interactiva. Se canjea una vez
  por un token y se descarta; no se guarda en ningún lado.
- **Token:** vive en el Llavero de macOS, nunca en disco ni en la configuración.
  - En las llamadas a la API va en el cuerpo del POST.
  - En las descargas va en la URL, porque Moodle lo exige, y solo si el archivo está en el mismo
    servidor (host y puerto) que el campus y por `https`.
  - Todo lo que se muestra o se loguea pasa por un redactor que lo tapa.
- **Nombres de archivo del campus:** se tratan como no confiables. Se quitan `..`, rutas absolutas,
  caracteres de control y caracteres invisibles de dirección de texto, y se verifica que la ruta
  final quede dentro del destino, también frente a enlaces simbólicos.
- **Markdown y avisos:** los nombres se escapan antes de escribirse en `NOVEDADES.md` y
  `_enlaces.md`, y solo `http`/`https` se vuelven enlaces. El aviso de macOS recibe los textos como
  argumentos y nunca los interpola en el AppleScript.

Para reportar una vulnerabilidad, ver [SECURITY.md](SECURITY.md).

## Desarrollo

```bash
swift build                                   # compilar
swift test                                    # tests (Swift Testing)
swift format lint -r Sources Tests Package.swift
```

Reglas del proyecto (cero dependencias, manejo del token, saneo de rutas): [AGENTS.md](AGENTS.md).
Decisiones de diseño: [docs/arch/decisions](docs/arch/decisions).

## Logs

- Sync programado: `~/Library/Logs/campus-sync.log`.
- Sync a mano: la salida de error de la terminal.

## Desinstalar

`scripts/uninstall.sh` quita la tarea programada y el binario. `campus-sync logout` borra el token.
El material descargado no se toca.

## Licencia

[MIT](LICENSE).
