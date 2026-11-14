#!/bin/bash
# Buscar archivos repetidos (idénticos) de 1 MB o más en la carpeta personal, sin carpetas ocultas ni Library.
# Solo lectura: el diagnóstico informa y termina con 10; no borra nada. Primero agrupa por tamaño y solo compara el
# contenido (huella md5) de los que miden lo mismo. Con los permisos de la persona (sudo -u) y con tope de tiempo.
set -u
usuario=${HP_USUARIO:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
TAM='function t(b) { return b >= 1073741824 ? sprintf("%.1f GB", b / 1073741824) : sprintf("%d MB", b / 1048576) }'

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar la carpeta de otra persona."; return 1; }
}
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" <&0 & local p=$!  # <&0: sin esto, bash le daría /dev/null como entrada a lo que corre de fondo
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &  # pkill: el hijo (sudo) avisa a su vez al resto
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  t=$(mktemp) && z=$(mktemp) && l=$(mktemp) && h=$(mktemp) && e=$(mktemp) || { echo "No pude crear un archivo temporal."; exit 1; }
  trap 'rm -f "$t" "$z" "$l" "$h" "$e"' EXIT
  cortada=0
  tope 200 como find "$casa" -xdev \( -name '.*' -o -path "$casa/Library" \) -prune -o -type f -size +1M \
    -exec stat -f '%z'$'\t''%N' {} + > "$t" 2> "$e" || [ $? -ne 124 ] || cortada=1
  # solo los que tienen el mismo tamaño que otro
  awk -F'\t' '{ n[$1]++; l[NR] = $0; s[NR] = $1 } END { for (i = 1; i <= NR; i++) if (n[s[i]] > 1) print l[i] }' "$t" > "$z"
  cut -f2- "$z" | tr '\n' '\0' > "$l"
  [ -s "$l" ] && { tope 300 como xargs -0 md5 -r < "$l" > "$h" 2>/dev/null || [ $? -ne 124 ] || cortada=1; }
  # «bytes que sobran<TAB>copias<TAB>tamaño<TAB>dos de las rutas», de más a menos espacio repetido
  g=$(awk 'NR == FNR { i = index($0, "\t"); tam[substr($0, i + 1)] = substr($0, 1, i - 1); next }
      { p = substr($0, 34); k = tam[p] "\t" substr($0, 1, 32); n[k]++; if (n[k] <= 2) r[k] = r[k] (n[k] > 1 ? "\t" : "") p }
      END { for (k in n) if (n[k] > 1) { split(k, a, "\t"); printf "%.0f\t%d\t%s\t%s\n", a[1] * (n[k] - 1), n[k], a[1], r[k] } }' "$z" "$h" | sort -t$'\t' -k1,1nr)
  if [ -z "$g" ]; then
    echo "No encontré archivos repetidos de 1 MB o más en tu carpeta personal."
  else
    echo "Encontré $(echo "$g" | wc -l | tr -d ' ') grupo(s) de archivos repetidos; ocupan $(echo "$g" | awk -F'\t' "$TAM"'{ s += $1 } END { print t(s) }') de más."
    echo "Los que más espacio repiten:"
    echo "$g" | head -5 | awk -F'\t' -v c="$casa/" "$TAM"'function r(p) { return index(p, c) == 1 ? "~/" substr(p, length(c) + 1) : p }
      { printf "- %d copias de %s: %s y %s\n", $2, t($3), r($4), r($5) }'
    echo "No borré nada. Revisa cuáles quieres conservar antes de borrar las copias."
  fi
  grep -q 'Operation not permitted' "$e" && echo "macOS no me dejó revisar algunas carpetas protegidas (como Documentos, Escritorio o Descargas): pide a soporte que le dé a Helpert «Acceso total al disco»."
  [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber más repetidos."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
