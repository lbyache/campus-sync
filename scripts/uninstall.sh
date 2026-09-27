#!/bin/zsh
# Quita la tarea programada y el binario. No toca el material descargado,
# los manifiestos ni el token del Llavero (para eso: campus-sync logout).
set -euo pipefail

LABEL="local.campus-sync"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/campus-sync"
echo "✔ Tarea programada y binario quitados."
