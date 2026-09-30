#!/bin/zsh
# Compila campus-sync en modo release, lo instala en ~/.local/bin y programa el sync periódico (semanal por defecto).
# Se corre a mano: modifica tu sesión (LaunchAgents). Para desinstalar: scripts/uninstall.sh
#
# Uso: scripts/install.sh [--semanal | --diario | --manual]
#   --semanal  domingo a las 10:00 (por defecto)
#   --diario   todos los días a las 08:00
#   --manual   sin corrida automática
# Después, si es la primera vez: campus-sync setup
set -euo pipefail

FRECUENCIA="semanal"
for arg in "$@"; do
  case "$arg" in
    --semanal) FRECUENCIA="semanal" ;;
    --diario) FRECUENCIA="diario" ;;
    --manual) FRECUENCIA="manual" ;;
    *) echo "Opción desconocida: $arg (usá --semanal, --diario o --manual)" >&2; exit 64 ;;
  esac
done

cd "$(dirname "$0")/.."
BIN_DIR="$HOME/.local/bin"

swift build -c release
mkdir -p "$BIN_DIR"
install -m 755 .build/release/campus-sync "$BIN_DIR/campus-sync"

# Con una firma ad hoc cada recompilación es "otro programa" para el Llavero y macOS vuelve a
# pedir permiso; desde launchd no hay a quién preguntarle y el sync falla (OSStatus -128).
# Firmado con el certificado Apple Development, la identidad se mantiene entre versiones.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier local.campus-sync "$BIN_DIR/campus-sync"
  echo "✔ Binario en $BIN_DIR/campus-sync (firmado con Apple Development)"
else
  echo "✔ Binario en $BIN_DIR/campus-sync (firma ad hoc: macOS va a pedir permiso al Llavero tras cada actualización)"
fi

# La tarea programada la genera el propio binario (un solo lugar, con tests).
"$BIN_DIR/campus-sync" programar "--$FRECUENCIA"

if ! print -r -- ":$PATH:" | grep -q ":$BIN_DIR:"; then
  echo "ℹ︎ Agregá $BIN_DIR a tu PATH para usar 'campus-sync' directo:"
  echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
fi
