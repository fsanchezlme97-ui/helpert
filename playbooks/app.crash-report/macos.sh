#!/bin/bash
# Ver por qué un programa se cierra solo: busca los informes de fallos (.ips y .crash) y de cuelgues (.hang) del programa
# de los últimos 14 días en /Library/Logs/DiagnosticReports y en el de la persona (leído con su usuario). Solo lectura:
# termina con 10. HP_PROGRAMA ya viene validado ([A-Za-z0-9._-]): en el patrón de find no hay comodines. Bash 3.2.
set -u
prog=$(echo "${HP_PROGRAMA:-}" | tr 'A-Z' 'a-z')
case $prog in libreoffice|writer|calc|impress) prog=soffice ;; esac
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
# informes del programa: «AAAA-MM-DD-HHMMSS tipo», uno por línea, ordenados
informes() {
  {
    find /Library/Logs/DiagnosticReports -maxdepth 2 -type f -mtime -14 -iname "*${prog}*" 2>/dev/null
    if [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; then
      como find "$casa/Library/Logs/DiagnosticReports" -maxdepth 2 -type f -mtime -14 -iname "*${prog}*" 2>/dev/null
    fi
  } | sed -nE 's/.*[-_]([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})[^/]*\.(ips|crash|hang)$/\1 \2/p' | sort -u
}
veces() { if [ "$1" -eq 1 ]; then echo "1 vez"; else echo "$1 veces"; fi; }

case ${1:-} in
diagnosticar)
  [ ${#prog} -ge 3 ] || { echo "Necesito el nombre del programa (al menos 3 letras)."; exit 1; }
  l=$(informes)
  f=$(printf '%s\n' "$l" | grep -cE ' (ips|crash)$'); h=$(printf '%s\n' "$l" | grep -c ' hang$')
  if [ "$f" -eq 0 ] && [ "$h" -eq 0 ]; then
    echo "No encontré cierres inesperados de «${HP_PROGRAMA:-}» en los informes de macOS de los últimos 14 días."
    echo "Si se cierra sin dejar rastro, puede ser un problema de su configuración: restablecerlo o reinstalarlo suele ayudar. Si sigue, avisa a soporte."
    exit 10
  fi
  partes=
  [ "$f" -gt 0 ] && partes="se cerró de golpe $(veces "$f")"
  [ "$h" -gt 0 ] && partes="${partes}${partes:+ y }se colgó $(veces "$h")"
  u=$(printf '%s\n' "$l" | tail -1 | sed -E 's/^[0-9]{4}-([0-9]{2})-([0-9]{2})-([0-9]{2})([0-9]{2}).*/\2\/\1 a las \3:\4/')
  echo "En los últimos 14 días, «${HP_PROGRAMA:-}» $partes; la última, el $u."
  if [ "$f" -gt 0 ]; then echo "Actualizarlo (App Store o el propio programa) o reinstalarlo suele ayudar. Si sigue, avisa a soporte."
  else echo "Cuando se cuelga, suele ser por falta de memoria o por un archivo muy grande: cierra otros programas mientras lo usas. Si sigue, avisa a soporte."; fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
