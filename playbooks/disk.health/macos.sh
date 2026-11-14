#!/bin/bash
# Revisar la salud del disco en macOS: el estado SMART que da diskutil de cada disco físico (Verificado o Fallando).
# Sin smartctl (no viene con macOS), no hay sectores ni desgaste: solo ese veredicto. Solo lectura: termina con 10.
set -u
discos() { diskutil list physical 2>/dev/null | awk '/^\/dev\/disk/ {sub("/dev/", "", $1); print $1}'; }
campo() { echo "$1" | sed -n "s/^ *$2: *//p" | head -1; }

case ${1:-} in
diagnosticar)
  command -v diskutil >/dev/null || { echo "No puedo revisar los discos de este Mac."; exit 1; }
  d=$(discos)
  [ -n "$d" ] || { echo "No encontré discos que revisar en este Mac."; exit 1; }
  lineas="" malos=0 sanos=0
  for x in $d; do
    i=$(diskutil info "$x" 2>/dev/null)
    case $(campo "$i" Protocol) in *"Disk Image"*) continue ;; esac
    n=$(campo "$i" 'Device \/ Media Name'); t=$(campo "$i" 'Disk Size' | sed -E 's/^([0-9.]+ [KMGT]B).*/\1/')
    quien="${n:-$x}${t:+ ($t)}"
    case $(campo "$i" 'SMART Status') in
      Verified) sanos=$((sanos + 1)); lineas="$lineas- $quien: sano."$'\n' ;;
      Failing) malos=$((malos + 1)); lineas="$lineas- $quien: el propio disco avisa que está fallando."$'\n' ;;
      *) lineas="$lineas- $quien: no informa su estado SMART."$'\n' ;;
    esac
  done
  if [ "$malos" -gt 0 ]; then echo "Conviene cambiar el disco: haz copia de tus archivos importantes cuanto antes (por ejemplo con Time Machine) y avisa a soporte."
  elif [ "$sanos" -gt 0 ]; then echo "El disco está sano según su estado SMART; no hace falta cambiarlo."
  else echo "Ningún disco de este Mac informa su estado SMART: no puedo decir si conviene cambiarlo. Pide a soporte que lo revise."; fi
  printf '%s' "$lineas" | head -5
  [ "$malos" -eq 0 ] && [ "$sanos" -gt 0 ] && echo "Si el Mac se sigue congelando, la causa puede ser otra (poca memoria o disco lleno): pide a soporte que lo revise."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
