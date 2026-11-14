#!/bin/bash
# Revisar la cámara en macOS: si el equipo la detecta (system_profiler) y qué programa la está usando, según lo último
# que anotó el Centro de control para el punto verde de la cámara (registro de la última hora). Solo lectura: termina
# con 10. Los permisos de cámara de cada programa (privacidad) no se leen: se dice dónde revisarlos. Bash 3.2.
set -u
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
# nombre de la app con ese identificador («us.zoom.xos» → «zoom.us»); el identificador si no la encuentra
app() {
  a=$(tope 2 mdfind "kMDItemCFBundleIdentifier == '$1'" 2>/dev/null | grep '\.app$' | head -1)
  if [ -n "$a" ]; then basename "$a" .app; else echo "$1"; fi
}
PERMISO="Si el programa dice que no hay cámara, dale permiso en Ajustes del Sistema > Privacidad y seguridad > Cámara."

case ${1:-} in
diagnosticar)
  camaras=$(tope 10 system_profiler SPCameraDataType 2>/dev/null | awk '/^    [^ ].*:$/ {sub(/^ +/, ""); sub(/:$/, ""); print}')
  if [ -z "$camaras" ]; then
    echo "El equipo no detecta ninguna cámara. Si es externa, desconéctala y conéctala en otro puerto; si es de la laptop, revisa que no esté tapada."
    exit 10
  fi
  nombre=$(echo "$camaras" | head -1)
  echo "El equipo detecta la cámara «${nombre}»."
  # «Active activity attributions changed to ["cam:us.zoom.xos", "mic:…"]»: solo letras, números, . _ - en cada id
  # si el registro se corta por tiempo, lo leído es viejo: no sirve
  linea=$(tope 10 log show --last 1h --style compact --predicate 'process == "ControlCenter" AND eventMessage CONTAINS "attributions changed"' 2>/dev/null) || linea=
  linea=$(echo "$linea" | grep 'attributions changed' | tail -1)
  usando=$(echo "$linea" | grep -o 'cam:[A-Za-z0-9._-]*' | cut -d: -f2 | sort -u | while read -r b; do [ -n "$b" ] && app "$b"; done | paste -sd, - | sed 's/,/, /g')
  if [ -n "$usando" ]; then echo "Ahora la está usando: $usando. Cierra ese programa y vuelve a abrir la videollamada."
  # «nadie» solo si la línea se entiende: una lista sin datos ocultos (<private>)
  elif echo "$linea" | grep -q 'changed to \[' && ! echo "$linea" | grep -q '<private>'; then echo "Ningún programa la está usando. En la videollamada, elige esta cámara en la configuración de video."
  else echo "No pude saber si algún programa la está usando: cierra los programas de videollamada que no uses y, en la que necesitas, elige esta cámara en la configuración de video."; fi
  echo "$PERMISO"
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
