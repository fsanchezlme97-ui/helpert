#!/bin/bash
# Restablecer LibreOffice: renombra el perfil de la persona (~/Library/Application Support/LibreOffice/4) a
# 4.helpert-<fecha> para que LibreOffice cree uno nuevo. Deshacer devuelve el más reciente (el nuevo queda a un lado).
# Los documentos no se tocan. Solo con LibreOffice cerrado; todo con el usuario de la persona (sudo -u). Bash 3.2.
set -u
NOMBRE=LibreOffice
PATRON='LibreOffice\.app/'  # procesos de la app, por la ruta de su ejecutable
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
OBJETO="$casa/Library/Application Support/LibreOffice/4"

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los programas de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
abierto() { pgrep -u "$usuario" -f "$PATRON" >/dev/null; }
hay() { como test -e "$OBJETO"; }
# copia más reciente (los nombres llevan la fecha, así que se ordenan solos)
respaldo() { como find "$(dirname "$OBJETO")" -mindepth 1 -maxdepth 1 -name "$(basename "$OBJETO").helpert-[0-9]*" 2>/dev/null | sort | tail -1; }
mover() {  # deja en $porque el motivo, si macOS no lo permite
  porque=
  e=$(como mv -- "$1" "$2" 2>&1) && return 0
  case $e in *"not permitted"*) porque=" macOS no deja a Helpert tocar esa carpeta (privacidad): soporte tiene que darle «Acceso total al disco»." ;; esac
  return 1
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  hay || { echo "No encontré un perfil de LibreOffice en tu carpeta: se crea solo la primera vez que lo abres."; exit 10; }
  echo "Encontré tu perfil de LibreOffice. Lo renombraría para que empiece con uno nuevo; tus documentos no se tocan."
  echo "Tus ajustes, diccionario personal y macros quedan guardados en el perfil viejo y se pueden recuperar deshaciendo."
  abierto && echo "$NOMBRE está abierto: ciérralo antes de que lo restablezca."
  exit 0 ;;
comprobar)
  puedo || exit 3
  hay || { echo "No hay perfil de LibreOffice que restablecer."; exit 3; }
  abierto && { echo "$NOMBRE está abierto: guarda tus documentos, ciérralo (Cmd+Q) y vuelve a pedírmelo."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  abierto && { echo "$NOMBRE está abierto: no toqué nada."; exit 1; }
  mover "$OBJETO" "$OBJETO.helpert-$(date +%Y%m%d-%H%M%S)" || { echo "No pude renombrar tu perfil de LibreOffice.$porque"; exit 1; }
  echo "Renombré tu perfil de LibreOffice. Ábrelo: empezará con la configuración inicial. Si quieres volver al anterior, se puede deshacer."
  exit 0 ;;
verificar)
  puedo || exit 1
  abierto && { echo "$NOMBRE ya está abierto con un perfil nuevo."; exit 0; }
  { ! hay && [ -n "$(respaldo)" ]; } || { echo "El perfil viejo de LibreOffice sigue en su lugar."; exit 1; }
  echo "Listo: LibreOffice creará un perfil nuevo al abrirlo."
  exit 0 ;;
deshacer)
  puedo || exit 1
  abierto && { echo "$NOMBRE está abierto: ciérralo (Cmd+Q) y vuelve a pedírmelo."; exit 1; }
  r=$(respaldo)
  [ -n "$r" ] || { echo "No encontré un perfil anterior de LibreOffice que devolver."; exit 1; }
  if hay; then mover "$OBJETO" "$OBJETO.helpert-nuevo-$(date +%Y%m%d-%H%M%S)" || { echo "No pude apartar el perfil nuevo.$porque"; exit 1; }; fi
  mover "$r" "$OBJETO" || { echo "No pude devolver tu perfil anterior de LibreOffice.$porque"; exit 1; }
  echo "Devolví tu perfil anterior de LibreOffice, con tus ajustes de antes."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
