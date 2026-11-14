#!/bin/bash
# Limpiar la caché del navegador en macOS: solo las carpetas de caché (en ~/Library/Caches), nunca el perfil
# (contraseñas, historial, cookies, que están en Application Support). Solo de navegadores cerrados: con el navegador
# abierto, la caché se vuelve a escribir y puede corromperse. Todo lo que toca la carpeta de la persona se hace con su
# usuario (sudo -u), nunca como root. Compatible con bash 3.2 (sin arreglos asociativos).
set -u
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
# navegador|carpeta dentro de ~/Library/Caches|nombre de su app (para saber si está abierto)
NAVEGADORES='Firefox|Firefox|Firefox
Chrome|Google/Chrome|Google Chrome
Chromium|Chromium|Chromium
Edge|Microsoft Edge|Microsoft Edge
Brave|BraveSoftware/Brave-Browser|Brave Browser'

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar el navegador de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@" </dev/null; else "$@" </dev/null; fi; }
# procesos de la persona dentro de la app (también sus ayudantes), por la ruta de su ejecutable
abierto() { pgrep -u "$usuario" -f "/$1\.app/" >/dev/null; }
mb() { k=$(como du -sk "$1" 2>/dev/null | cut -f1); echo $(( ${k:-0} / 1024 )); }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  hay=0
  while IFS='|' read -r n c a; do
    d="$casa/Library/Caches/$c"
    como test -d "$d" || continue
    hay=1
    if abierto "$a"; then echo "$n: $(mb "$d") MB de caché (está abierto: ciérralo antes de que lo limpie)"
    else echo "$n: $(mb "$d") MB de caché."; fi
  done <<EOF
$NAVEGADORES
EOF
  [ "$hay" = 1 ] || { echo "No encontré caché de navegadores en tu carpeta."; exit 10; }
  exit 0 ;;
comprobar)
  puedo || exit 3
  exit 0 ;;
aplicar)
  puedo || exit 1
  limpios= abiertos= tcc=
  while IFS='|' read -r n c a; do
    d="$casa/Library/Caches/$c"
    como test -d "$d" || continue
    if abierto "$a"; then abiertos="$abiertos, $n"; continue; fi
    # con el usuario de la persona y sin seguir enlaces: find -delete no entra en ellos
    como find "$d" -mindepth 1 -delete 2>&1 >/dev/null | grep 'not permitted' >/dev/null && tcc=1
    limpios="$limpios, $n"
  done <<EOF
$NAVEGADORES
EOF
  limpios=${limpios#, } abiertos=${abiertos#, }
  [ -z "$tcc" ] || { echo "macOS no deja a Helpert borrar la caché del navegador (privacidad). Soporte tiene que darle «Acceso total al disco»."; exit 1; }
  [ -n "$limpios$abiertos" ] || { echo "No encontré caché de navegadores que limpiar."; exit 0; }
  [ -n "$limpios" ] || { echo "No limpié nada: $abiertos sigue abierto. Ciérralo y vuelve a pedírmelo."; exit 1; }
  echo "Limpié la caché de: $limpios.${abiertos:+ No toqué $abiertos porque estaba abierto.}"
  exit 0 ;;
verificar)
  puedo || exit 1
  # lo que quede de navegadores cerrados son archivos que no se pudieron borrar
  q=0 cuales=
  while IFS='|' read -r n c a; do
    d="$casa/Library/Caches/$c"
    como test -d "$d" || continue
    abierto "$a" && continue
    k=$(mb "$d"); [ "$k" -gt 0 ] && cuales="$cuales, $n"; q=$((q + k))
  done <<EOF
$NAVEGADORES
EOF
  [ "$q" -le 5 ] || { echo "No pude borrar $q MB de caché de ${cuales#, }."; exit 1; }
  echo "Listo. Abre de nuevo el navegador y la página; la primera vez puede tardar un poco más."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
