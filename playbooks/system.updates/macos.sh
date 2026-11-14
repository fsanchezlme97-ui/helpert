#!/bin/bash
# Revisar las actualizaciones pendientes de macOS (softwareupdate -l: busca, no descarga ni instala) y si alguna
# pide reiniciar. Solo lectura: termina con 10.
set -u
case ${1:-} in
diagnosticar)
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  softwareupdate -l >"$tmp" 2>&1
  if grep -q 'No new software available' "$tmp"; then echo "macOS está al día: no hay actualizaciones pendientes."; exit 10; fi
  n=$(grep -c 'Title:' "$tmp")
  if [ "$n" -eq 0 ]; then
    echo "No pude consultar las actualizaciones de Apple. Revisa que tengas Internet; si sigue igual, avisa a soporte."
    exit 1
  fi
  echo "Hay $n actualización(es) pendiente(s):"
  # «Title: macOS Sonoma 14.5, Version: 14.5, Size: ..., Recommended: YES, Action: restart,»
  sed -n 's/.*Title: \([^,]*\),.*Version: \([^,]*\),.*/- \1 (\2)/p' "$tmp" | head -6
  [ "$n" -gt 6 ] && echo "- y $((n - 6)) más."
  grep -q 'Action: restart' "$tmp" && echo "Alguna de ellas reinicia el equipo al instalarse."
  echo "Instalarlas lo programa soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
