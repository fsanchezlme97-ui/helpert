#!/bin/bash
# Reparar la búsqueda de Thunderbird: cierra Thunderbird de la persona y borra el índice de búsqueda global
# (global-messages-db.sqlite de cada perfil); Thunderbird lo rehace solo. Los correos no se tocan.
# Todo lo que toca la carpeta de la persona se hace con su usuario, nunca como root.
set -u
PROC='thunderbird|thunderbird-bin'
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && getent passwd "$usuario" | cut -d: -f6)
BASES=("$casa/.thunderbird" "$casa/.var/app/org.mozilla.Thunderbird/.thunderbird" "$casa/snap/thunderbird/common/.thunderbird")

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los programas de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
abierto() { pgrep -u "$usuario" -x "$PROC" >/dev/null; }
cerrar() {  # primero se le pide cerrar (así guarda lo pendiente) y, si no responde, a la fuerza
  abierto || return 0
  pkill -TERM -u "$usuario" -x "$PROC" 2>/dev/null
  for _ in $(seq 15); do sleep 1; abierto || return 0; done
  pkill -KILL -u "$usuario" -x "$PROC" 2>/dev/null; sleep 1
  ! abierto
}
# archivos del índice (con sus -journal / -wal), uno por línea; el perfil está en <base>/<perfil>/
indices() { for b in "${BASES[@]}"; do como find "$b" -mindepth 2 -maxdepth 2 -type f -name 'global-messages-db.sqlite*' 2>/dev/null; done; }
mb() { [ $# -gt 0 ] && como du -sck "$@" 2>/dev/null | tail -1 | awk '{printf "%d", $1 / 1024}'; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  mapfile -t lista < <(indices)
  [ ${#lista[@]} -gt 0 ] || { echo "No encontré el índice de búsqueda de Thunderbird: o no lo usas en este equipo o tiene la búsqueda global desactivada."; exit 10; }
  echo "El índice de búsqueda de Thunderbird ocupa $(mb "${lista[@]}") MB. Lo borraría; Thunderbird lo rehace solo y tus correos no se tocan."
  abierto && echo "Thunderbird está abierto: lo voy a cerrar antes."
  exit 0 ;;
comprobar)
  puedo || exit 3
  mapfile -t lista < <(indices)
  [ ${#lista[@]} -gt 0 ] || { echo "No hay índice de búsqueda que borrar."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  cerrar || { echo "No pude cerrar Thunderbird, así que no borré nada."; exit 1; }
  for b in "${BASES[@]}"; do como find "$b" -mindepth 2 -maxdepth 2 -type f -name 'global-messages-db.sqlite*' -delete 2>/dev/null; done
  echo "Cerré Thunderbird y borré su índice de búsqueda. Ábrelo y déjalo abierto un rato: rehace el índice solo (con mucho correo puede tardar horas)."
  exit 0 ;;
verificar)
  puedo || exit 1
  abierto && { echo "Thunderbird está abierto y rehaciendo su índice."; exit 0; }
  [ -z "$(indices)" ] || { echo "No pude borrar el índice de búsqueda de Thunderbird."; exit 1; }
  echo "Listo: el índice viejo ya no está. Abre Thunderbird para que lo rehaga."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
