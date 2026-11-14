#!/bin/bash
# Reparar la plantilla de Word: renombra la plantilla Normal de la persona (Normal.dotm, en el grupo de Office de
# ~/Library/Group Containers) a Normal.dotm.helpert-<fecha> para que Word cree una nueva. Deshacer la devuelve (la nueva
# queda a un lado). Solo con Word cerrado; todo con el usuario de la persona (sudo -u). Bash 3.2.
set -u
NOMBRE=Word
PATRON='Microsoft Word\.app/'  # procesos de la app, por la ruta de su ejecutable
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
# Office 2016 y posteriores; las versiones nuevas usan las carpetas «.localized»
GRUPO="$casa/Library/Group Containers/UBF8T346G9.Office"
OBJETO="$GRUPO/User Content.localized/Templates.localized/Normal.dotm"

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los programas de otra persona."; return 1; }
  # versiones viejas, sin «.localized» (revisado con el usuario de la persona)
  if ! como test -d "$GRUPO/User Content.localized" && como test -d "$GRUPO/User Content/Templates"; then
    OBJETO="$GRUPO/User Content/Templates/Normal.dotm"
  fi
  return 0
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
  hay || { echo "No encontré tu plantilla Normal de Word: Word crea una nueva al abrirse, así que no es la causa."; exit 10; }
  echo "Encontré tu plantilla Normal de Word. La renombraría para que Word cree una nueva, limpia; tus documentos no se tocan."
  echo "Si guardaste en ella estilos, macros o autotextos, quedan en la copia y se pueden recuperar deshaciendo."
  abierto && echo "$NOMBRE está abierto: ciérralo antes de que cambie la plantilla."
  exit 0 ;;
comprobar)
  puedo || exit 3
  hay || { echo "No hay plantilla Normal que renombrar."; exit 3; }
  abierto && { echo "$NOMBRE está abierto: guarda tus documentos, ciérralo (Cmd+Q) y vuelve a pedírmelo."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  abierto && { echo "$NOMBRE está abierto: no toqué nada."; exit 1; }
  mover "$OBJETO" "$OBJETO.helpert-$(date +%Y%m%d-%H%M%S)" || { echo "No pude renombrar tu plantilla Normal.$porque"; exit 1; }
  echo "Renombré tu plantilla Normal. Abre Word: creará una nueva. Si quieres volver a la anterior, se puede deshacer."
  exit 0 ;;
verificar)
  puedo || exit 1
  abierto && { echo "$NOMBRE ya está abierto con una plantilla nueva."; exit 0; }
  { ! hay && [ -n "$(respaldo)" ]; } || { echo "La plantilla Normal vieja sigue en su lugar."; exit 1; }
  echo "Listo: Word creará una plantilla Normal nueva al abrirse."
  exit 0 ;;
deshacer)
  puedo || exit 1
  abierto && { echo "$NOMBRE está abierto: ciérralo (Cmd+Q) y vuelve a pedírmelo."; exit 1; }
  r=$(respaldo)
  [ -n "$r" ] || { echo "No encontré una copia de tu plantilla Normal que devolver."; exit 1; }
  if hay; then mover "$OBJETO" "$OBJETO.helpert-nuevo-$(date +%Y%m%d-%H%M%S)" || { echo "No pude apartar la plantilla nueva.$porque"; exit 1; }; fi
  mover "$r" "$OBJETO" || { echo "No pude devolver tu plantilla Normal.$porque"; exit 1; }
  echo "Devolví tu plantilla Normal anterior. Abre Word de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
