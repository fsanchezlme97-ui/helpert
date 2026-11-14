#!/bin/bash
# Desbloquear el perfil del navegador: si Firefox, Chrome, Edge, Brave o Chromium de la persona de verdad están cerrados
# (ningún proceso suyo de esa app), quita el bloqueo que quedó: «.parentlock» y «lock» de los perfiles de Firefox,
# «Singleton*» de los de Chrome y parecidos. Nada más del perfil. Con el usuario de la persona (sudo -u). Bash 3.2.
set -u
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
NAVS='Firefox Chrome Edge Brave Chromium'
AS="$casa/Library/Application Support"

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar el navegador de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
patron() {  # procesos de la app, por la ruta de su ejecutable
  case $1 in Firefox) echo 'Firefox[^/]*\.app/' ;; Chrome) echo 'Google Chrome\.app/' ;; Edge) echo 'Microsoft Edge\.app/' ;;
    Brave) echo 'Brave Browser\.app/' ;; Chromium) echo 'Chromium\.app/' ;; esac
}
base() {
  case $1 in Firefox) echo "$AS/Firefox/Profiles" ;; Chrome) echo "$AS/Google/Chrome" ;; Edge) echo "$AS/Microsoft Edge" ;;
    Brave) echo "$AS/BraveSoftware/Brave-Browser" ;; Chromium) echo "$AS/Chromium" ;; esac
}
abierto() { pgrep -u "$usuario" -f "$(patron "$1")" >/dev/null; }
# bloqueos del navegador $1 (uno por línea); con $2 = -delete, los borra. find no sigue los enlaces: borra el enlace.
bloqueos() {
  if [ "$1" = Firefox ]; then como find "$(base "$1")" -mindepth 2 -maxdepth 2 \( -name .parentlock -o -name lock \) ${2:+"$2"} 2>/dev/null
  else como find "$(base "$1")" -mindepth 1 -maxdepth 1 -name 'Singleton*' ${2:+"$2"} 2>/dev/null; fi
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  quitar=0 abiertos=
  for n in $NAVS; do
    [ -n "$(bloqueos "$n")" ] || continue
    if abierto "$n"; then abiertos="$abiertos${abiertos:+, }$n"; else quitar=1; echo "$n: quedó un bloqueo del perfil y el navegador está cerrado; lo puedo quitar."; fi
  done
  [ -n "$abiertos" ] && echo "$abiertos sigue abierto para ti, aunque no se vea una ventana: no es un bloqueo que haya quedado. Ciérralo con Cmd+Q o desde el menú Apple > Forzar salida."
  [ "$quitar" = 1 ] && exit 0
  [ -n "$abiertos" ] || echo "No encontré ningún perfil de navegador bloqueado en tu carpeta."
  exit 10 ;;
comprobar)
  puedo || exit 3
  for n in $NAVS; do [ -n "$(bloqueos "$n")" ] && ! abierto "$n" && exit 0; done
  echo "No hay bloqueos que quitar en navegadores cerrados."
  exit 3 ;;
aplicar)
  puedo || exit 1
  hechos=
  for n in $NAVS; do
    { [ -n "$(bloqueos "$n")" ] && ! abierto "$n"; } || continue
    bloqueos "$n" -delete; hechos="$hechos${hechos:+, }$n"
  done
  [ -n "$hechos" ] || { echo "No quité nada: el navegador está abierto o ya no tenía bloqueo."; exit 1; }
  echo "Quité el bloqueo del perfil de: $hechos. Ya puedes abrirlo."
  exit 0 ;;
verificar)
  puedo || exit 1
  for n in $NAVS; do
    [ -n "$(bloqueos "$n")" ] && ! abierto "$n" && { echo "$n sigue con el perfil bloqueado: no pude quitar el bloqueo."; exit 1; }
  done
  echo "Listo: ningún navegador cerrado tiene el perfil bloqueado. Ábrelo de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
