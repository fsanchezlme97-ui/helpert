#!/bin/bash
# Limpiar los datos de Zoom: cierra Zoom de la persona y vacía sus carpetas de datos y registros (~/.zoom/data y logs,
# también la de Flatpak), salvo los fondos virtuales propios (VirtualBkgnd_*). Hay que volver a iniciar sesión.
# Las grabaciones (en Documentos/Zoom) no se tocan.
# Todo lo que toca la carpeta de la persona se hace con su usuario, nunca como root.
set -u
PROC='zoom|zoom\.real|ZoomLauncher|ZoomWebviewHost|aomhost'
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && getent passwd "$usuario" | cut -d: -f6)
CARPETAS=("$casa/.zoom/data" "$casa/.zoom/logs" "$casa/.var/app/us.zoom.Zoom/.zoom/data" "$casa/.var/app/us.zoom.Zoom/.zoom/logs")

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los programas de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
abierto() { pgrep -u "$usuario" -x "$PROC" >/dev/null; }
cerrar() {  # primero se le pide cerrar y, si no responde, a la fuerza
  abierto || return 0
  pkill -TERM -u "$usuario" -x "$PROC" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8; do sleep 1; abierto || return 0; done
  pkill -KILL -u "$usuario" -x "$PROC" 2>/dev/null; sleep 1
  ! abierto
}
# lo que hay dentro de esas carpetas (uno por línea), menos los fondos virtuales; revisado con el usuario de la persona
datos() { for d in "${CARPETAS[@]}"; do como find "$d" -mindepth 1 -maxdepth 1 ! -name 'VirtualBkgnd_*' 2>/dev/null; done; }
mb() { [ $# -gt 0 ] && como du -sck "$@" 2>/dev/null | tail -1 | awk '{printf "%d", $1 / 1024}'; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  mapfile -t lista < <(datos)
  [ ${#lista[@]} -gt 0 ] || { echo "No encontré datos de Zoom en tu carpeta: o no lo usas en este equipo o ya están limpios."; exit 10; }
  echo "Zoom tiene $(mb "${lista[@]}") MB de datos temporales. Los borraría; después tendrás que volver a iniciar sesión en Zoom."
  abierto && echo "Zoom está abierto: lo voy a cerrar antes de limpiar (si estás en una reunión, se corta)."
  exit 0 ;;
comprobar)
  puedo || exit 3
  mapfile -t lista < <(datos)
  [ ${#lista[@]} -gt 0 ] || { echo "No hay datos de Zoom que limpiar."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  cerrar || { echo "No pude cerrar Zoom, así que no borré nada."; exit 1; }
  mapfile -t lista < <(datos)
  antes=$(mb "${lista[@]}")
  for d in "${lista[@]}"; do como rm -rf -- "$d" 2>/dev/null; done
  echo "Cerré Zoom y borré sus datos temporales (${antes:-0} MB). Ábrelo e inicia sesión de nuevo."
  exit 0 ;;
verificar)
  puedo || exit 1
  abierto && { echo "Zoom ya está abierto de nuevo."; exit 0; }
  mapfile -t lista < <(datos)
  q=$(mb "${lista[@]}")
  [ "${q:-0}" -le 2 ] || { echo "No pude borrar $q MB de datos de Zoom."; exit 1; }
  echo "Listo: los datos de Zoom están limpios. Ábrelo e inicia sesión de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
