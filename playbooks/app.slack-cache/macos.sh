#!/bin/bash
# Limpiar la caché de Slack (descargado o de la App Store): cierra Slack de la persona y vacía solo sus carpetas de caché
# (Library/Caches y las Cache, Code Cache, GPUCache, CacheStorage de sus datos). Los mensajes están en la nube. Todo lo que toca la carpeta de la persona se hace con su usuario (sudo -u), nunca como root. Bash 3.2.
set -u
NOMBRE=Slack
PATRON='Slack\.app/'  # procesos de la app (y sus ayudantes), por la ruta de su ejecutable
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
# carpetas cuyo contenido se borra (una por línea), buscadas con el usuario de la persona
objetivos() {
  como test -d "$casa/Library/Caches/com.tinyspeck.slackmacgap" && echo "$casa/Library/Caches/com.tinyspeck.slackmacgap"
  for b in "$casa/Library/Application Support/Slack" "$casa/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack"; do
    como find "$b" -maxdepth 4 -type d \( -name Cache -o -name 'Code Cache' -o -name GPUCache -o -name CacheStorage \
      -o -name ScriptCache \) -prune -print 2>/dev/null
  done
}
mb() {  # suma en MB de las carpetas que llegan por la entrada
  t=0
  while IFS= read -r d; do [ -n "$d" ] || continue; k=$(como du -sk "$d" 2>/dev/null | cut -f1); t=$((t + ${k:-0})); done
  echo $((t / 1024))
}
# vacía las carpetas; escribe «tcc» si macOS no dejó entrar (privacidad: falta «Acceso total al disco»)
vaciar() { objetivos | while IFS= read -r d; do como find "$d" -mindepth 1 -delete 2>&1 >/dev/null; done | grep -q 'Operation not permitted' && echo tcc; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  [ -n "$(objetivos)" ] || { echo "No encontré la caché de $NOMBRE en tu carpeta: o no lo usas en este equipo o ya está limpia."; exit 10; }
  echo "$NOMBRE tiene $(objetivos | mb) MB de caché. La borraría; tus mensajes están en la nube."
  abierto && echo "$NOMBRE está abierto: lo voy a cerrar antes de limpiar."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(objetivos)" ] || { echo "No hay caché de $NOMBRE que limpiar."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  cerrar || { echo "No pude cerrar $NOMBRE, así que no borré nada."; exit 1; }
  antes=$(objetivos | mb)
  [ -z "$(vaciar)" ] || { echo "macOS no deja a Helpert borrar la caché de $NOMBRE (privacidad). Soporte tiene que darle «Acceso total al disco»."; exit 1; }
  echo "Cerré $NOMBRE y borré su caché ($antes MB). Ábrelo de nuevo: la primera vez tarda un poco más."
  exit 0 ;;
verificar)
  puedo || exit 1
  abierto && { echo "$NOMBRE ya está abierto de nuevo y está armando su caché."; exit 0; }
  q=$(objetivos | mb)
  [ "$q" -le 5 ] || { echo "No pude borrar $q MB de la caché de $NOMBRE."; exit 1; }
  echo "Listo: la caché de $NOMBRE está limpia. Ábrelo de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
