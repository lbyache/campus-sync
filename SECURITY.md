# Política de seguridad

`campus-sync` maneja una credencial con acceso a toda la vida académica de quien lo usa, así que los
reportes de seguridad se toman en serio.

## Cómo reportar una vulnerabilidad

**No abras un issue público.** Usá el reporte privado de GitHub: pestaña *Security* del repositorio ›
*Report a vulnerability*. Incluí:

- qué versión o commit usaste;
- cómo reproducirlo (idealmente con un campus de prueba, no con datos reales de nadie);
- qué impacto tiene: exposición del token, escritura fuera de la carpeta destino, etc.

La idea es responder dentro de los 7 días y publicar el arreglo junto con un aviso de seguridad. Si
el reporte se confirma, se reconoce a quien lo hizo, salvo que prefiera no figurar.

## Versiones con soporte

Solo la última versión de la rama principal.

## Qué está dentro del alcance

- Filtración del token de Moodle: en logs, errores, archivos, o enviado a un host distinto del campus.
- Escritura fuera de la carpeta destino a partir de nombres de archivo del servidor (path traversal,
  enlaces simbólicos, Unicode).
- Inyección en `NOVEDADES.md`, `_enlaces.md` o en el aviso de macOS a partir de contenido del campus.
- Cualquier forma de que la contraseña del campus quede guardada o se muestre.

## Qué está fuera del alcance

- Vulnerabilidades del propio servidor Moodle o de la configuración de una institución.
- Ataques que requieren acceso previo a la sesión de macOS de la persona usuaria (con eso ya se
  puede leer el Llavero desbloqueado).
- El contenido de los archivos descargados: `campus-sync` no los abre ni los ejecuta.

## Modelo de amenazas, en breve

- **El servidor es no confiable** en todo lo que devuelve: nombres, rutas, URLs y textos.
- El token solo vive en el Llavero y solo viaja al host del campus por HTTPS.
- La herramienta no tiene dependencias de terceros, así que no hay cadena de suministro fuera del
  toolchain de Apple.

Detalle y mitigaciones: [docs/arch/decisions/0001](docs/arch/decisions/0001-campus-sync-descargador-propio.md)
y la sección *Seguridad* del [README](README.md).
