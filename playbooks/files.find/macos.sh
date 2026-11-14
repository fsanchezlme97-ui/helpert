#!/bin/bash
# Buscar un archivo por nombre en la carpeta personal de la persona y en su papelera (~/.Trash). Solo lectura: el
# diagnóstico busca y termina con 10. Con los permisos de la persona (sudo -u), nunca como root, y con tope de tiempo.
# Sin carpetas ocultas ni Library (datos de programas). HP_NOMBRE ya viene validado: letras, números, . _ - (sin comodines).
set -u
usuario=${HP_USUARIO:-}
nombre=${HP_NOMBRE:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona pide la búsqueda o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo buscar en la carpeta de otra persona."; return 1; }
  [ -n "$nombre" ] || { echo "Necesito una palabra del nombre del archivo."; return 1; }
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
# «época<TAB>fecha<TAB>ruta» de lo que tiene la palabra en el nombre, bajo $1 (sin entrar en ocultas ni en Library)
buscar() {
  como find "$1" -xdev -mindepth 1 \( -name '.*' -o -path "$casa/Library" \) -prune -o -iname "*$nombre*" \
    -exec stat -t '%Y-%m-%d %H:%M' -f '%m'$'\t''%Sm'$'\t''%N' {} +
}
# los 15 más recientes, con la ruta corta (~/… o lo que quede tras $2)
lista() { sort -rn "$1" | head -15 | awk -F'\t' -v c="$2" -v p="$3" '{ n = $3; if (index(n, c) == 1) n = substr(n, length(c) + 1); print $2 "  " p n }'; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  h=$(mktemp) && t=$(mktemp) && e=$(mktemp) || { echo "No pude crear un archivo temporal."; exit 1; }
  trap 'rm -f "$h" "$t" "$e"' EXIT
  cortada=0
  tope 40 buscar "$casa" > "$h" 2> "$e" || [ $? -ne 124 ] || cortada=1
  [ -d "$casa/.Trash" ] && { tope 10 buscar "$casa/.Trash" > "$t" 2>> "$e" || [ $? -ne 124 ] || cortada=1; }
  hallados=$(lista "$h" "$casa/" "~/")
  papelera=$(lista "$t" "$casa/.Trash/" "papelera: ")
  if [ -z "$hallados$papelera" ]; then
    echo "No encontré archivos con «${nombre}» en el nombre dentro de tu carpeta personal ni en la papelera."
    echo "Prueba con otra palabra del nombre, o puede estar en una memoria USB, una carpeta compartida, iCloud Drive u OneDrive (búscalo con el Finder)."
  else
    [ -n "$hallados" ] && { echo "Encontré estos archivos con «${nombre}» en el nombre (los más recientes primero):"; echo "$hallados"; }
    [ -n "$papelera" ] && { echo "En la papelera (puedes recuperarlos desde ahí):"; echo "$papelera"; }
  fi
  grep -q 'Operation not permitted' "$e" && echo "macOS no me dejó buscar en algunas carpetas protegidas (como Documentos, Escritorio, Descargas o la papelera): pide a soporte que le dé a Helpert «Acceso total al disco»."
  [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber más."
  exit 10 ;;
*) echo "Este procedimiento solo busca; no cambia nada."; exit 2 ;;
esac
