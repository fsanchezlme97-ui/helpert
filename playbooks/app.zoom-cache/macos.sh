#!/bin/bash
# Limpiar los datos de Zoom: cierra Zoom de la persona y vacía sus datos y registros (Application Support/zoom.us/data,
# Logs/zoom.us, Caches/us.zoom.xos), salvo los fondos virtuales propios (VirtualBkgnd_*). Hay que volver a iniciar
# sesión. Las grabaciones (en Documentos/Zoom) no se tocan. Todo lo que toca la carpeta de la persona se hace con su usuario (sudo -u), nunca como root. Bash 3.2.
set -u
NOMBRE=Zoom
PATRON='zoom\.us\.app/'  # procesos de la app (y sus ayudantes), por la ruta de su ejecutable
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los programas de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
abierto() { pgrep -u "$usuario" -f "$PATRON" >/dev/null; }
cerrar() {  # primero se le pide cerrar y, si no responde, a la fuerza
  abierto || return 0
  pkill -TERM -u "$usuario" -f "$PATRON" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8; do sleep 1; abierto || return 0; done
  pkill -KILL -u "$usuario" -f "$PATRON" 2>/dev/null; sleep 1
  ! abierto
}
# lo que hay dentro de las carpetas de datos (uno por línea), menos los fondos virtuales; con el usuario de la persona
objetivos() {
  for d in "$casa/Library/Application Support/zoom.us/data" "$casa/Library/Logs/zoom.us" "$casa/Library/Caches/us.zoom.xos"; do
    como find "$d" -mindepth 1 -maxdepth 1 ! -name 'VirtualBkgnd_*' 2>/dev/null
  done
}
mb() {  # suma en MB de lo que llega por la entrada
  t=0
  while IFS= read -r d; do [ -n "$d" ] || continue; k=$(como du -sk "$d" 2>/dev/null | cut -f1); t=$((t + ${k:-0})); done
  echo $((t / 1024))
}
# borra cada cosa; escribe «tcc» si macOS no dejó entrar (privacidad: falta «Acceso total al disco»)
vaciar() { objetivos | while IFS= read -r d; do como rm -rf -- "$d" 2>&1 >/dev/null; done | grep -q 'not permitted' && echo tcc; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  [ -n "$(objetivos)" ] || { echo "No encontré datos de Zoom en tu carpeta: o no lo usas en este equipo o ya están limpios."; exit 10; }
  echo "Zoom tiene $(objetivos | mb) MB de datos temporales. Los borraría; después tendrás que volver a iniciar sesión en Zoom."
  abierto && echo "Zoom está abierto: lo voy a cerrar antes de limpiar (si estás en una reunión, se corta)."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(objetivos)" ] || { echo "No hay datos de Zoom que limpiar."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  cerrar || { echo "No pude cerrar $NOMBRE, así que no borré nada."; exit 1; }
  antes=$(objetivos | mb)
  [ -z "$(vaciar)" ] || { echo "macOS no deja a Helpert borrar los datos de Zoom (privacidad). Soporte tiene que darle «Acceso total al disco»."; exit 1; }
  echo "Cerré Zoom y borré sus datos temporales ($antes MB). Ábrelo e inicia sesión de nuevo."
  exit 0 ;;
verificar)
  puedo || exit 1
  abierto && { echo "Zoom ya está abierto de nuevo."; exit 0; }
  q=$(objetivos | mb)
  [ "$q" -le 2 ] || { echo "No pude borrar $q MB de datos de Zoom."; exit 1; }
  echo "Listo: los datos de Zoom están limpios. Ábrelo e inicia sesión de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
