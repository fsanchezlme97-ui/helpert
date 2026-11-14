#!/bin/bash
# Reparar la búsqueda de Thunderbird: cierra Thunderbird de la persona y borra el índice de búsqueda global
# (global-messages-db.sqlite de cada perfil de ~/Library/Thunderbird/Profiles); Thunderbird lo rehace solo. Los correos
# no se tocan. Todo lo que toca la carpeta de la persona se hace con su usuario (sudo -u), nunca como root. Bash 3.2.
set -u
PATRON='Thunderbird[^/]*\.app/'  # procesos de la app, por la ruta de su ejecutable
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
BASE="$casa/Library/Thunderbird/Profiles"

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los programas de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
abierto() { pgrep -u "$usuario" -f "$PATRON" >/dev/null; }
cerrar() {  # primero se le pide cerrar (así guarda lo pendiente) y, si no responde, a la fuerza
  abierto || return 0
  pkill -TERM -u "$usuario" -f "$PATRON" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do sleep 1; abierto || return 0; done
  pkill -KILL -u "$usuario" -f "$PATRON" 2>/dev/null; sleep 1
  ! abierto
}
# archivos del índice (con sus -journal / -wal), uno por línea; $1 = -delete los borra
indices() { como find "$BASE" -mindepth 2 -maxdepth 2 -type f -name 'global-messages-db.sqlite*' ${1:+"$1"} 2>/dev/null; }
mb() {  # suma en MB de los archivos que llegan por la entrada
  t=0
  while IFS= read -r f; do [ -n "$f" ] || continue; k=$(como du -sk "$f" 2>/dev/null | cut -f1); t=$((t + ${k:-0})); done
  echo $((t / 1024))
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  [ -n "$(indices)" ] || { echo "No encontré el índice de búsqueda de Thunderbird: o no lo usas en este equipo o tiene la búsqueda global desactivada."; exit 10; }
  echo "El índice de búsqueda de Thunderbird ocupa $(indices | mb) MB. Lo borraría; Thunderbird lo rehace solo y tus correos no se tocan."
  abierto && echo "Thunderbird está abierto: lo voy a cerrar antes."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(indices)" ] || { echo "No hay índice de búsqueda que borrar."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  cerrar || { echo "No pude cerrar Thunderbird, así que no borré nada."; exit 1; }
  indices -delete
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
