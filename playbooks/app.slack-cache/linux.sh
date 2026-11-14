#!/bin/bash
# Limpiar la caché de Slack (paquete, Flatpak y Snap): cierra Slack de la persona y vacía solo sus
# carpetas de caché (Cache, Code Cache, GPUCache, CacheStorage, ScriptCache). Los mensajes están en la nube.
# Todo lo que toca la carpeta de la persona se hace con su usuario, nunca como root.
set -u
NOMBRE=Slack
PROC='slack'
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && getent passwd "$usuario" | cut -d: -f6)
BASES=("$casa/.config/Slack" "$casa/.var/app/com.slack.Slack/config/Slack" "$casa/snap/slack/current/.config/Slack")

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
# carpetas de caché (una por línea), buscadas con el usuario de la persona
caches() {
  for b in "${BASES[@]}"; do
    como find "$b" -maxdepth 4 -type d \( -name Cache -o -name 'Code Cache' -o -name GPUCache -o -name CacheStorage \
      -o -name ScriptCache \) -prune -print 2>/dev/null
  done
}
mb() { [ $# -gt 0 ] && como du -sck "$@" 2>/dev/null | tail -1 | awk '{printf "%d", $1 / 1024}'; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  mapfile -t lista < <(caches)
  [ ${#lista[@]} -gt 0 ] || { echo "No encontré la caché de $NOMBRE en tu carpeta: o no lo usas en este equipo o ya está limpia."; exit 10; }
  echo "$NOMBRE tiene $(mb "${lista[@]}") MB de caché. La borraría; tus mensajes están en la nube."
  abierto && echo "$NOMBRE está abierto: lo voy a cerrar antes de limpiar."
  exit 0 ;;
comprobar)
  puedo || exit 3
  mapfile -t lista < <(caches)
  [ ${#lista[@]} -gt 0 ] || { echo "No hay caché de $NOMBRE que limpiar."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  cerrar || { echo "No pude cerrar $NOMBRE, así que no borré nada."; exit 1; }
  mapfile -t lista < <(caches)
  antes=$(mb "${lista[@]}")
  for d in "${lista[@]}"; do como find "$d" -mindepth 1 -delete 2>/dev/null; done
  echo "Cerré $NOMBRE y borré su caché (${antes:-0} MB). Ábrelo de nuevo: la primera vez tarda un poco más."
  exit 0 ;;
verificar)
  puedo || exit 1
  abierto && { echo "$NOMBRE ya está abierto de nuevo y está armando su caché."; exit 0; }
  mapfile -t lista < <(caches)
  q=$(mb "${lista[@]}")
  [ "${q:-0}" -le 5 ] || { echo "No pude borrar $q MB de la caché de $NOMBRE."; exit 1; }
  echo "Listo: la caché de $NOMBRE está limpia. Ábrelo de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
