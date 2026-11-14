#!/bin/bash
# Ver los últimos archivos que la persona modificó en su carpeta personal (30 días, sin carpetas ocultas ni Library,
# que son de programas). Solo lectura: termina con 10. Con los permisos de la persona (sudo -u) y con tope de tiempo.
set -u
usuario=${HP_USUARIO:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar la carpeta de otra persona."; return 1; }
}
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
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
  t=$(mktemp) && e=$(mktemp) || { echo "No pude crear un archivo temporal."; exit 1; }
  trap 'rm -f "$t" "$e"' EXIT
  cortada=0
  tope 90 como find "$casa" -xdev \( -name '.*' -o -path "$casa/Library" \) -prune -o -type f -mtime -30 \
    -exec stat -t '%Y-%m-%d %H:%M' -f '%m'$'\t''%Sm'$'\t''%N' {} + > "$t" 2> "$e" || [ $? -ne 124 ] || cortada=1
  l=$(sort -rn "$t" | head -10 | awk -F'\t' -v c="$casa/" '{ n = $3; if (index(n, c) == 1) n = substr(n, length(c) + 1); print $2 "  ~/" n }')
  if [ -z "$l" ]; then
    echo "No encontré archivos tuyos modificados en los últimos 30 días dentro de tu carpeta personal."
    echo "Puede estar en una memoria USB, una carpeta de red o en iCloud; si recuerdas parte del nombre, usa la búsqueda del Finder."
  else
    echo "Estos son los últimos archivos que modificaste (los más recientes primero):"
    echo "$l"
  fi
  grep -q 'Operation not permitted' "$e" && echo "macOS no me dejó revisar algunas carpetas protegidas (como Documentos, Escritorio o Descargas): pide a soporte que le dé a Helpert «Acceso total al disco»."
  [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber otros más recientes."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
