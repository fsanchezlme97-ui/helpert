#!/bin/bash
# Encontrar lo que más ocupa en la carpeta personal (macOS, bash 3.2 y herramientas BSD). Solo lectura: termina con 10.
# Todo con los permisos de la persona (sudo -u) y con tope de tiempo (macOS no trae timeout).
set -u
usuario=${HP_USUARIO:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
TAM='function t(k) { return k >= 1048576 ? sprintf("%.1f GB", k / 1048576) : sprintf("%d MB", k / 1024) }'

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar la carpeta de otra persona."; return 1; }
}
tope() {  # corre «$2...» con un tope de $1 segundos; sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &  # pkill: el hijo (sudo) avisa a su vez a find
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  d=$(mktemp) && f=$(mktemp) && e=$(mktemp) || { echo "No pude crear un archivo temporal."; exit 1; }
  trap 'rm -f "$d" "$f" "$e"' EXIT
  cortada=0
  tope 150 como find "$casa" -mindepth 1 -maxdepth 1 -exec du -xsk {} + > "$d" 2> "$e" || [ $? -ne 124 ] || cortada=1
  tope 100 como find "$casa" -xdev -type f -size +100M -exec stat -f '%z'$'\t''%N' {} + > "$f" 2>> "$e" || [ $? -ne 124 ] || cortada=1
  total=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$d")
  [ "${total:-0}" -gt 0 ] || { echo "Tu carpeta personal está vacía o no pude leerla."; exit 10; }
  libre=$(df -g "$casa" 2>/dev/null | awk 'NR == 2 { print $4 }')
  echo "Tu carpeta personal ocupa $(awk "$TAM"' BEGIN { print t('"$total"') }')${libre:+; en el disco quedan $libre GB libres}."
  echo "Lo que más ocupa: $(sort -t$'\t' -k1,1nr "$d" | head -5 | awk -F'\t' -v c="$casa/" "$TAM"'
    { n = $2; if (index(n, c) == 1) n = substr(n, length(c) + 1); printf "%s%s (%s)", s, n, t($1); s = ", " }')."
  grandes=$(sort -t$'\t' -k1,1nr "$f" | head -5 | awk -F'\t' -v c="$casa/" "$TAM"'
    { n = $2; if (index(n, c) == 1) n = substr(n, length(c) + 1); printf "- ~/%s (%s)\n", n, t($1 / 1024) }')
  [ -n "$grandes" ] && { echo "Los archivos más grandes:"; echo "$grandes"; }
  echo "Library guarda datos de programas; para limpiar temporales y caché usa «Liberar espacio en disco»."
  grep -q 'Operation not permitted' "$e" && echo "macOS no me dejó revisar algunas carpetas protegidas (como Documentos, Escritorio o Descargas): pide a soporte que le dé a Helpert «Acceso total al disco»."
  [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: las cifras son de lo que alcancé a ver."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
