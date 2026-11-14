#!/bin/bash
# Ver qué programa usa internet (macOS): los 5 programas con más conexiones abiertas (TCP establecidas y UDP
# conectadas, con lsof), sin contar las del propio equipo. Cuenta conexiones, no lo que gasta cada una. Solo revisa.
set -u
con_limite() {  # macOS no trae timeout: corta la orden a los $1 segundos
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; kill "$p" ) >/dev/null 2>&1 &
  local w=$!
  wait "$p"; local r=$?
  kill "$w" 2>/dev/null
  return $r
}

case ${1:-} in
diagnosticar)
  command -v lsof >/dev/null || { echo "Falta la herramienta lsof en este equipo para ver las conexiones."; exit 1; }
  # +c 0: el nombre completo del programa (lsof cambia sus espacios por «\x20»); la conexión es el campo con «->»
  top=$(con_limite 20 lsof -nP -b +c 0 -iTCP -sTCP:ESTABLISHED -iUDP 2>/dev/null | awk '
    NR > 1 {for (i = 9; i <= NF; i++) if ($i ~ /->/) {
      if ($i !~ /->(127\.|\[::1\]|\[::ffff:127\.)/) {p = $1; gsub(/\\x20/, " ", p); n[p]++; t++}
      break }}
    END {for (p in n) print n[p] "\t" p; if (t) print t "\tTOTAL"}' | sort -t "$(printf '\t')" -k1,1nr)
  total=$(printf '%s\n' "$top" | awk -F'\t' '$2 == "TOTAL" {print $1}')
  [ -n "$total" ] || { echo "Ahora mismo ningún programa está conectado a internet."; exit 10; }
  lista=$(printf '%s\n' "$top" | awk -F'\t' '$2 != "TOTAL"' | head -5)
  primero=$(printf '%s\n' "$lista" | head -1 | cut -f2); n1=$(printf '%s\n' "$lista" | head -1 | cut -f1)
  echo "El programa con más conexiones abiertas es $primero ($n1 de $total)."
  printf '%s\n' "$lista" | awk -F'\t' '{print "- " $2 ": " $1 " conexión(es)"}'
  echo "Muchas conexiones no siempre es mucho consumo, pero las descargas, las actualizaciones y la sincronización con la nube suelen ser las que más gastan."
  echo "Si no estás usando alguno, puedes cerrarlo tú; yo no cierro nada."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
