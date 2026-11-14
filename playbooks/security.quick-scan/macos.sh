#!/bin/bash
# Análisis rápido en macOS con Microsoft Defender (mdatp), el único antivirus del Mac que Helpert sabe lanzar.
# XProtect, el de macOS, analiza solo en segundo plano y no tiene un análisis que se pueda pedir: sin Defender, no aplica.
# No borra ni mueve nada por su cuenta: lo que Defender aísle según su configuración queda en su cuarentena.
set -u
export LC_ALL=C
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
sano() { [ "$(tope 20 mdatp health --field healthy 2>/dev/null | tr -d '[:space:]"')" = true ]; }
puedo() {
  command -v mdatp >/dev/null || { echo "Este Mac solo tiene XProtect, el antivirus de macOS, que revisa solo y en segundo plano: no permite lanzar un análisis a mano. No instalo otro antivirus: si hace falta, lo decide soporte."; return 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para usar el antivirus."; return 1; }
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  sano || { echo "Microsoft Defender está instalado, pero no está funcionando bien (puede faltarle la licencia o las firmas): avisa a soporte."; exit 1; }
  echo "Puedo hacer un análisis rápido con Microsoft Defender de las partes del Mac donde suele esconderse algo dudoso."
  echo "Tarda unos minutos. No borro nada: te digo qué encontró, y lo que Defender aísle queda en cuarentena."
  exit 0 ;;
comprobar)
  puedo || exit 3
  sano || { echo "Microsoft Defender no está funcionando bien: avisa a soporte."; exit 3; }
  exit 0 ;;
aplicar)
  command -v mdatp >/dev/null || { echo "Microsoft Defender ya no está instalado."; exit 1; }
  salida=$(tope 1700 mdatp scan quick 2>/dev/null); r=$?
  [ "$r" -eq 124 ] && { tope 30 mdatp scan cancel >/dev/null 2>&1; echo "El análisis tardó demasiado y lo detuve."; exit 1; }
  n=$(printf '%s\n' "$salida" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\) threat(s) detected.*/\1/p' | head -1)
  [ -n "$n" ] || { echo "El antivirus no pudo terminar el análisis."; exit 1; }
  if [ "$n" -gt 0 ]; then
    echo "El antivirus encontró $n archivo(s) peligroso(s):"
    printf '%s\n' "$salida" | sed -n 's/^[[:space:]]*Name: *//p' | awk '!visto[$0]++' | head -5 | sed 's/^/- /'
    echo "No borré nada: lo que Microsoft Defender aisló queda en cuarentena. No abras esos archivos y avisa a soporte; devolver uno lo decide soporte."
    exit 0
  fi
  echo "El análisis rápido terminó y no encontró nada peligroso."
  exit 0 ;;
verificar)
  command -v mdatp >/dev/null && sano || { echo "El antivirus ya no está funcionando bien."; exit 1; }
  echo "El análisis terminó; Microsoft Defender sigue funcionando."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
