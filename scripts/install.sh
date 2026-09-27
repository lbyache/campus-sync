#!/bin/zsh
# Compila campus-sync en modo release, lo instala en ~/.local/bin y programa el sync periódico (semanal por defecto).
# Se corre a mano: modifica tu sesión (LaunchAgents). Para desinstalar: scripts/uninstall.sh
#
# Uso: scripts/install.sh [--semanal | --diario]
#   --semanal  domingo a las 10:00 (por defecto)
#   --diario   todos los días a las 08:00
set -euo pipefail

FRECUENCIA="semanal"
for arg in "$@"; do
  case "$arg" in
    --semanal) FRECUENCIA="semanal" ;;
    --diario) FRECUENCIA="diario" ;;
    *) echo "Opción desconocida: $arg (usá --semanal o --diario)" >&2; exit 64 ;;
  esac
done

if [[ "$FRECUENCIA" == "diario" ]]; then
  SCHEDULE='{"Hour":8,"Minute":0}'
  DESCRIPCION="todos los días a las 08:00"
else
  SCHEDULE='{"Weekday":0,"Hour":10,"Minute":0}'   # Weekday 0 = domingo
  DESCRIPCION="una vez por semana, domingo 10:00"
fi

cd "$(dirname "$0")/.."
LABEL="local.campus-sync"
BIN_DIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

swift build -c release
mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 .build/release/campus-sync "$BIN_DIR/campus-sync"

# Con una firma ad hoc cada recompilación es "otro programa" para el Llavero y macOS vuelve a
# pedir permiso; desde launchd no hay a quién preguntarle y el sync falla (OSStatus -128).
# Firmado con el certificado Apple Development, la identidad se mantiene entre versiones.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier "$LABEL" "$BIN_DIR/campus-sync"
  echo "✔ Binario en $BIN_DIR/campus-sync (firmado con Apple Development)"
else
  echo "✔ Binario en $BIN_DIR/campus-sync (firma ad hoc: macOS va a pedir permiso al Llavero tras cada actualización)"
fi

sed "s#__HOME__#$HOME#g" launchd/$LABEL.plist > "$PLIST"
plutil -replace StartCalendarInterval -json "$SCHEDULE" "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✔ Sync programado: $DESCRIPCION (log: ~/Library/Logs/campus-sync.log)"

if ! print -r -- ":$PATH:" | grep -q ":$BIN_DIR:"; then
  echo "ℹ︎ Agregá $BIN_DIR a tu PATH para usar 'campus-sync' directo:"
  echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
fi
