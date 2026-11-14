#!/bin/bash
# Revisar errores del sistema de archivos sin reparar nada (solo lectura: termina con 10). Revisa en vivo el volumen de
# datos (donde están los archivos de las personas) con diskutil verifyVolume, que no repara; el equipo puede ir más
# lento un rato mientras tanto. También avisa si el volumen quedó en solo lectura.
set -u

case ${1:-} in
diagnosticar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para revisar el disco."; exit 3; }
  vol=/System/Volumes/Data; [ -d "$vol" ] || vol=/
  salida=$(diskutil verifyVolume "$vol" 2>&1); c=$?
  if diskutil info "$vol" 2>/dev/null | grep -Eq 'Volume Read-Only: +Yes'; then
    echo "El disco de tus archivos está en solo lectura: macOS lo protegió al encontrar un error."
    echo "Guarda lo que puedas y pide a soporte que lo repare desde la recuperación de macOS (al reiniciar)."
    exit 10
  fi
  if [ "$c" -eq 0 ]; then
    echo "No encontré errores en el disco: el sistema de archivos está bien y no hace falta repararlo."
    echo "Si un programa dice que un archivo está dañado, puede ser solo ese archivo: prueba con una copia de Time Machine."
    exit 10
  fi
  if grep -Eqi 'corrupt|invalid|needs to be repaired|incorrect' <<< "$salida"; then
    echo "El disco tiene errores que hay que reparar."
    echo "Guarda tu trabajo y pide a soporte que lo repare con Utilidad de Discos desde la recuperación de macOS (al reiniciar)."
    exit 10
  fi
  echo "No pude revisar el disco ahora (puede estar ocupado). Prueba de nuevo en un rato."
  exit 1 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
