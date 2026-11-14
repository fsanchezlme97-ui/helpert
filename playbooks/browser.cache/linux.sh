#!/bin/bash
# Limpiar la caché del navegador: solo las carpetas de caché (en ~/.cache), nunca el perfil (contraseñas, historial,
# cookies). Solo de navegadores cerrados: con el navegador abierto, la caché se vuelve a escribir y puede corromperse.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
# carpeta de caché por navegador y el nombre de su proceso
declare -A CACHE=([Firefox]=mozilla/firefox [Chrome]=google-chrome [Chromium]=chromium [Edge]=microsoft-edge [Brave]=BraveSoftware/Brave-Browser)
declare -A PROC=([Firefox]=firefox [Chrome]=chrome [Chromium]=chromium [Edge]=msedge [Brave]=brave)

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar el navegador de otra persona."; return 1; }
}
abierto() { pgrep -u "$usuario" -x "${PROC[$1]}" >/dev/null || pgrep -u "$usuario" -f "/${PROC[$1]}( |$)" >/dev/null; }
mb() { du -sm "$1" 2>/dev/null | cut -f1; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  hay=0
  for n in "${!CACHE[@]}"; do
    d="$casa/.cache/${CACHE[$n]}"
    [ -d "$d" ] || continue
    hay=1; echo -n "$n: $(mb "$d") MB de caché"
    abierto "$n" && echo " (está abierto: ciérralo antes de que lo limpie)" || echo "."
  done
  [ "$hay" = 1 ] || { echo "No encontré caché de navegadores en tu carpeta."; exit 10; }
  exit 0 ;;
comprobar)
  puedo || exit 3
  exit 0 ;;
aplicar)
  limpios=() abiertos=()
  for n in "${!CACHE[@]}"; do
    d="$casa/.cache/${CACHE[$n]}"
    [ -d "$d" ] || continue
    if abierto "$n"; then abiertos+=("$n"); continue; fi
    # la carpeta es del usuario: se borra con sus permisos, sin seguir enlaces fuera de ella
    if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- find "$d" -mindepth 1 -delete 2>/dev/null
    else find "$d" -mindepth 1 -delete 2>/dev/null; fi
    limpios+=("$n")
  done
  [ ${#limpios[@]} -gt 0 ] || { echo "No limpié nada: ${abiertos[*]} sigue abierto. Ciérralo y vuelve a pedírmelo."; exit 1; }
  echo "Limpié la caché de: ${limpios[*]}.${abiertos[*]:+ No toqué ${abiertos[*]} porque estaba abierto.}"
  exit 0 ;;
verificar)
  echo "Listo. Abre de nuevo el navegador y la página; la primera vez puede tardar un poco más."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
