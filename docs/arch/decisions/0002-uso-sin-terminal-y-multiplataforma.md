# 0002. Uso sin terminal y soporte para otros sistemas operativos

## Estado
Accepted (2026-09-27). Se empieza por la fase 1.

## Contexto

La versión 0.1 funciona, pero solo para alguien técnico con una Mac:

- Hay que clonar el repo, tener Xcode o las Command Line Tools y compilar.
- La configuración se hace por terminal y editando un JSON a mano: ids de cursos, alias, rutas como
  `~/Library/CloudStorage/…`.
- Ya aparecieron errores de uso reales: pegar el link web de Drive en lugar de la ruta local, o
  guardar una ruta sin la carpeta personal.
- Solo corre en macOS. Una parte grande de quienes estudian usa Windows, y algunos Linux.

**Objetivo:** que alguien sin conocimientos técnicos lo pueda instalar y usar en minutos, sin romper
los principios del ADR 0001: sin dependencias de terceros, el código que toca la credencial es
propio, y el token nunca sale de la máquina.

**Restricción clave:** no hay servidor. Una versión web o "en la nube" obligaría a guardar los tokens
de otras personas en un servidor ajeno. Eso contradice el ADR 0001 y suma un riesgo legal y de
seguridad que el proyecto no puede asumir. Queda descartada.

## Opciones consideradas

### Experiencia de uso

| # | Opción | Qué resuelve | Costo / riesgo |
|---|---|---|---|
| U1 | **Asistente guiado `campus-sync setup`** | Un solo comando que pregunta en lenguaje llano: comprueba que el campus tenga el servicio móvil, muestra las carpetas de Google Drive o OneDrive detectadas para elegir por número, lista los cursos para marcar, propone nombres cortos, deja elegir la frecuencia, hace la primera sincronización y programa las siguientes. Reemplaza editar JSON. | Bajo. Todo en `CampusSyncCore`, testeable. Sigue siendo terminal, pero una sola vez. |
| U2 | **Binarios listos para descargar** (GitHub Releases, compilados por CI) | No hace falta Xcode ni compilar. | Bajo. En macOS, sin notarización (requiere el Apple Developer Program, US$ 99/año), Gatekeeper advierte al abrir; se documenta cómo permitirlo. |
| U3 | **App de barra de menú en macOS** (SwiftUI) | Estado visible (al día / N novedades), botón "Sincronizar ahora", preferencias con ventanas y selector de carpetas nativo. Sin terminal. | Medio. Reutiliza `CampusSyncCore`. Para distribuirla sin advertencias hace falta notarizarla. Solo macOS. |
| U4 | Versión web o servicio en la nube | Cualquier dispositivo. | **Descartada**: guardaría credenciales de terceros en un servidor. |

### Multiplataforma

| # | Opción | A favor | En contra |
|---|---|---|---|
| P1 | **Swift en macOS, Linux y Windows**, con una capa de plataforma | Swift tiene toolchains oficiales para las tres plataformas. Casi todo `CampusSyncCore` es Foundation puro. Se mantiene el código y los tests. | Hay que abstraer lo que hoy es de Apple: Llavero, launchd, avisos y SHA-256 (CryptoKit no existe fuera de Apple). |
| P2 | Reescribir en Go o Rust | Un binario estático por plataforma y distribución trivial. | Se reescribe todo. Las bibliotecas de llavero multiplataforma son dependencias externas (choca con el ADR 0001). |
| P3 | Solo documentar la opción manual para Windows y Linux | Costo cero. | No resuelve el problema. |

**Capa de plataforma de P1** (protocolos en `CampusSyncCore` con una implementación por sistema, sin
dependencias: cada una usa herramientas del propio sistema operativo):

| Protocolo | macOS | Windows | Linux |
|---|---|---|---|
| `SecretStore` | Llavero (Security.framework) | Administrador de credenciales (API `CredRead`/`CredWrite` de Win32, disponible desde Swift) | Secret Service (`secret-tool` de libsecret) |
| `Scheduler` | launchd | Programador de tareas (`schtasks`) | temporizador de usuario de systemd |
| `Notifier` | `osascript` | notificación de PowerShell | `notify-send` |
| `SHA256` | CryptoKit | implementación propia (~100 líneas, verificada con los vectores oficiales de NIST) | ídem |

## Matriz de decisión

Puntaje de 1 a 5; total ponderado sobre 100.

| Criterio | Peso | U1 + U2 + P1 | U3 (app macOS) | P2 (reescritura) |
|---|---:|---:|---:|---:|
| Llega a quien no es técnico | 25 | 4 | 5 | 4 |
| Llega a Windows y Linux | 25 | 5 | 1 | 5 |
| Respeta el ADR 0001 (sin dependencias, credencial local) | 20 | 5 | 5 | 2 |
| Esfuerzo | 15 | 3 | 3 | 1 |
| Mantenimiento | 15 | 3 | 3 | 2 |
| **Total** | 100 | **83** | **68** | **62** |

## Decisión propuesta

**U1 + U2 + P1, por fases.** U3 (app de barra de menú) queda como fase opcional para macOS.

| Fase | Alcance | Valor por sí sola |
|---|---|---|
| 1 | `campus-sync setup`: asistente guiado. La frecuencia elegida se aplica sin scripts. | Nadie edita JSON ni rutas a mano. |
| 2 | Binarios en GitHub Releases para macOS (universal), compilados y firmados por CI. | Se instala sin Xcode. |
| 3 | Capa de plataforma (`SecretStore`, `Scheduler`, `Notifier`, SHA-256 propio) + soporte y CI para **Windows**. | La mayoría de los estudiantes. |
| 4 | Soporte y CI para **Linux**. | Completa la cobertura. |
| 5 (opcional) | App de barra de menú para macOS. | Uso sin terminal en Mac. |

## Consecuencias

- **Positivas:** una sola base de código y los mismos tests en las tres plataformas; sigue sin
  dependencias ni servidor; el asistente guiado también evita los errores de ruta ya vistos.
- **Negativas:**
  - Tres implementaciones de plataforma para mantener, cada una con su CI.
  - Windows y Linux se prueban en CI, pero sin un uso real diario hasta que alguien los adopte.
  - Sin el Apple Developer Program, los binarios de macOS muestran una advertencia de Gatekeeper
    la primera vez.
- **Riesgos:**
  - Diferencias de Foundation fuera de Apple (por ejemplo `URLSession` en Linux): se mitigan corriendo
    la misma suite de tests en las tres plataformas en CI.
  - SHA-256 propio: se verifica con los vectores de prueba oficiales y solo se usa para detectar
    cambios, no para seguridad.
  - Almacenamiento de secretos en Linux sin Secret Service (servidores sin escritorio): falla con un
    mensaje claro y nunca cae en un archivo de texto plano.

## Referencias
- Swift en Windows y Linux: https://www.swift.org/install/
- Win32 Credential Management: https://learn.microsoft.com/windows/win32/secauthn/credentials-management
- libsecret / Secret Service: https://specifications.freedesktop.org/secret-service/
- Temporizadores de systemd: https://www.freedesktop.org/software/systemd/man/systemd.timer.html
- Notarización de Apple: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Vectores de prueba de SHA-256 (NIST): https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program
