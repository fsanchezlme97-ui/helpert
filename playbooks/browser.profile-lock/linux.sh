#!/bin/bash
# Desbloquear el perfil del navegador: si Firefox, Chrome, Chromium, Edge o Brave de la persona de verdad están cerrados
# (ningún proceso suyo con ese nombre), quita el bloqueo que quedó: «lock» y «.parentlock» de los perfiles de Firefox,
# «Singleton*» de los de Chrome y parecidos. Nada más del perfil. Con el usuario de la persona, nunca como root.
set -u
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && getent passwd "$usuario" | cut -d: -f6)
NAVS=(Firefox Chrome Chromium Edge Brave)
declare -A PROC=([Firefox]='firefox|firefox-bin|firefox-esr' [Chrome]=chrome [Chromium]=chromium [Edge]=msedge [Brave]=brave)

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar el navegador de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
abierto() { pgrep -u "$usuario" -x "${PROC[$1]}" >/dev/null || pgrep -u "$usuario" -f "/(${PROC[$1]})( |$)" >/dev/null; }
bases() {
  case $1 in
  Firefox) printf '%s\n' "$casa/.mozilla/firefox" "$casa/.config/mozilla/firefox" "$casa/snap/firefox/common/.mozilla/firefox" \
             "$casa/.var/app/org.mozilla.firefox/.mozilla/firefox" ;;
  Chrome) printf '%s\n' "$casa/.config/google-chrome" "$casa/.var/app/com.google.Chrome/config/google-chrome" ;;
  Chromium) printf '%s\n' "$casa/.config/chromium" "$casa/snap/chromium/common/chromium" "$casa/.var/app/org.chromium.Chromium/config/chromium" ;;
  Edge) printf '%s\n' "$casa/.config/microsoft-edge" "$casa/.var/app/com.microsoft.Edge/config/microsoft-edge" ;;
  Brave) printf '%s\n' "$casa/.config/BraveSoftware/Brave-Browser" "$casa/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser" ;;
  esac
}
# bloqueos del navegador $1 (uno por línea); con $2 = -delete, los borra. find no sigue los enlaces: borra el enlace.
bloqueos() {
  while IFS= read -r b; do
    # en Firefox, «.parentlock» existe siempre: el bloqueo que quedó es «lock»; al quitarlo se borran los dos
    if [ "$1" = Firefox ]; then
      if [ "${2:-}" = -delete ]; then como find "$b" -mindepth 2 -maxdepth 2 \( -name lock -o -name .parentlock \) -delete 2>/dev/null
      else como find "$b" -mindepth 2 -maxdepth 2 -name lock 2>/dev/null; fi
    else como find "$b" -maxdepth 1 -name 'Singleton*' ${2:+"$2"} 2>/dev/null; fi
  done < <(bases "$1")
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  quitar=0 abiertos=()
  for n in "${NAVS[@]}"; do
    [ -n "$(bloqueos "$n")" ] || continue
    if abierto "$n"; then abiertos+=("$n"); else quitar=1; echo "$n: quedó un bloqueo del perfil y el navegador está cerrado; lo puedo quitar."; fi
  done
  [ ${#abiertos[@]} -gt 0 ] && echo "${abiertos[*]} sigue abierto para ti, aunque no se vea una ventana: no es un bloqueo que haya quedado. Ciérralo con «Cerrar un programa congelado» o cierra tu sesión y vuelve a entrar."
  [ "$quitar" = 1 ] && exit 0
  [ ${#abiertos[@]} -gt 0 ] || echo "No encontré ningún perfil de navegador bloqueado en tu carpeta."
  exit 10 ;;
comprobar)
  puedo || exit 3
  for n in "${NAVS[@]}"; do [ -n "$(bloqueos "$n")" ] && ! abierto "$n" && exit 0; done
  echo "No hay bloqueos que quitar en navegadores cerrados."
  exit 3 ;;
aplicar)
  puedo || exit 1
  hechos=()
  for n in "${NAVS[@]}"; do
    { [ -n "$(bloqueos "$n")" ] && ! abierto "$n"; } || continue
    bloqueos "$n" -delete; hechos+=("$n")
  done
  [ ${#hechos[@]} -gt 0 ] || { echo "No quité nada: el navegador está abierto o ya no tenía bloqueo."; exit 1; }
  echo "Quité el bloqueo del perfil de: ${hechos[*]}. Ya puedes abrirlo."
  exit 0 ;;
verificar)
  puedo || exit 1
  for n in "${NAVS[@]}"; do
    [ -n "$(bloqueos "$n")" ] && ! abierto "$n" && { echo "$n sigue con el perfil bloqueado: no pude quitar el bloqueo."; exit 1; }
  done
  echo "Listo: ningún navegador cerrado tiene el perfil bloqueado. Ábrelo de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
