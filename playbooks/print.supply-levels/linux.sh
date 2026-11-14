#!/bin/bash
# Ver el nivel de tóner o tinta: lo que la impresora informó a CUPS (marker-names y marker-levels, que lpoptions
# muestra). HP_IMPRESORA (opcional) se busca sin distinguir mayúsculas; sin él, todas. Solo lectura: termina con 10.
set -u
pedida=${HP_IMPRESORA:-}
BAJO=15

impresoras() {
  if [ -z "$pedida" ]; then lpstat -e 2>/dev/null | head -6; return; fi
  e=$(lpstat -e 2>/dev/null | grep -ixF -- "$pedida" | head -1)
  [ -n "$e" ] || e=$(lpstat -e 2>/dev/null | grep -iF -- "$pedida" | head -1)
  echo "$e"
}
# «nombre|nivel» por cada tóner o tinta; xargs deshace las comillas y barras de lpoptions sin interpretar nada
niveles() {
  t=$(lpoptions -p "$1" 2>/dev/null | xargs -n1 printf '%s\n' 2>/dev/null)
  n=$(echo "$t" | sed -n 's/^marker-names=//p'); l=$(echo "$t" | sed -n 's/^marker-levels=//p')
  [ -n "$n" ] && [ -n "$l" ] || return 0
  awk -v n="$n" -v l="$l" 'BEGIN { k = split(n, a, ","); split(l, b, ","); for (i = 1; i <= k; i++) print a[i] "|" b[i] }'
}
# «Negro 72 %, Cian 10 % (bajo)»; marca $bajo=1 si alguno está bajo
texto() {
  echo "$1" | awk -F'|' -v umbral="$BAJO" '
    { v = $2 + 0
      if ($2 == "" || v == -1 || v == -2) s = $1 " (no informa)"
      else if (v == -3) s = $1 " (le queda algo)"
      else { s = $1 " " v " %"; if (v <= umbral) { s = s " (bajo)"; bajo = 1 } }
      out = out (NR > 1 ? ", " : "") s }
    END { print (bajo ? "1" : "0") "|" out }'
}

case ${1:-} in
diagnosticar)
  { command -v lpstat >/dev/null && command -v lpoptions >/dev/null; } || { echo "Este equipo no tiene el sistema de impresión (CUPS) instalado."; exit 1; }
  ps=$(impresoras)
  if [ -z "$ps" ]; then
    [ -n "$pedida" ] && { echo "No encontré la impresora «$pedida» en este equipo."; exit 1; }
    echo "Este equipo no tiene impresoras instaladas."; exit 10
  fi
  lineas="" bajas="" informan=0
  while read -r p; do
    nv=$(niveles "$p")
    if [ -z "$nv" ]; then lineas="$lineas- $p: no informa sus niveles."$'\n'; continue; fi
    informan=1; r=$(texto "$nv")
    lineas="$lineas- $p: ${r#*|}."$'\n'
    [ "${r%%|*}" = 1 ] && bajas="${bajas:+$bajas, }«$p»"
  done <<< "$ps"
  if [ "$informan" = 0 ]; then
    echo "La impresora no le informa a este equipo cuánto tóner o tinta le queda. Míralo en la pantalla de la impresora o pide a soporte que lo revise."
    exit 10
  fi
  if [ -n "$bajas" ]; then echo "A $bajas le queda poco tóner o tinta: avisa a soporte para que un técnico lo cambie."
  else echo "Estos son los niveles de tóner o tinta que informan las impresoras:"; fi
  printf '%s' "$lineas"
  echo "Son los últimos que informó cada impresora; algunas solo los actualizan después de imprimir."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
