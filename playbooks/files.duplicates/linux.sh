#!/bin/bash
# Buscar archivos repetidos (idénticos) de 1 MB o más en la carpeta personal, sin carpetas ocultas de programas.
# Solo lectura: el diagnóstico informa y termina con 10; no borra nada. Primero agrupa por tamaño y solo compara el
# contenido (huella md5) de los que miden lo mismo. Con los permisos de la persona (runuser) y con tope de tiempo.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
TAM='function t(b) { return b >= 1073741824 ? sprintf("%.1f GB", b / 1073741824) : sprintf("%d MB", b / 1048576) }'

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar la carpeta de otra persona."; return 1; }
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  t=$(mktemp) && h=$(mktemp) || { echo "No pude crear un archivo temporal."; exit 1; }
  trap 'rm -f "$t" "$h"' EXIT
  # «tamaño<TAB>ruta» de los que tienen el mismo tamaño que otro
  como timeout 200 find "$casa" -xdev \( -name '.*' -prune \) -o -type f -size +1M -printf '%s\t%p\n' 2>/dev/null |
    awk -F'\t' '{ n[$1]++; l[NR] = $0; s[NR] = $1 } END { for (i = 1; i <= NR; i++) if (n[s[i]] > 1) print l[i] }' > "$t"
  c1=${PIPESTATUS[0]}
  cut -f2- "$t" | como timeout 300 xargs -d '\n' -r md5sum -- > "$h" 2>/dev/null
  c2=${PIPESTATUS[1]}
  # shortcut: rutas con «\» o saltos de línea (md5sum las escapa) no se agrupan; son rarísimas en carpetas personales
  # «bytes que sobran<TAB>copias<TAB>tamaño<TAB>dos de las rutas», de más a menos espacio repetido
  g=$(awk 'NR == FNR { i = index($0, "\t"); tam[substr($0, i + 1)] = substr($0, 1, i - 1); next }
      { p = substr($0, 35); k = tam[p] "\t" substr($0, 1, 32); n[k]++; if (n[k] <= 2) r[k] = r[k] (n[k] > 1 ? "\t" : "") p }
      END { for (k in n) if (n[k] > 1) { split(k, a, "\t"); printf "%.0f\t%d\t%s\t%s\n", a[1] * (n[k] - 1), n[k], a[1], r[k] } }' "$t" "$h" | sort -t$'\t' -k1,1nr)
  if [ -z "$g" ]; then
    echo "No encontré archivos repetidos de 1 MB o más en tu carpeta personal."
  else
    echo "Encontré $(grep -c . <<< "$g") grupo(s) de archivos repetidos; ocupan $(awk -F'\t' "$TAM"'{ s += $1 } END { print t(s) }' <<< "$g") de más."
    echo "Los que más espacio repiten:"
    head -5 <<< "$g" | awk -F'\t' -v c="$casa/" "$TAM"'function r(p) { return index(p, c) == 1 ? "~/" substr(p, length(c) + 1) : p }
      { printf "- %d copias de %s: %s y %s\n", $2, t($3), r($4), r($5) }'
    echo "No borré nada. Revisa cuáles quieres conservar antes de borrar las copias."
  fi
  { [ "$c1" -eq 124 ] || [ "$c2" -eq 124 ]; } && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber más repetidos."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
