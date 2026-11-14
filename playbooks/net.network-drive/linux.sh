#!/bin/bash
# Reconectar unidades de red: las de /etc/fstab de tipo cifs, smb3 o nfs que no estén montadas.
set -u
de_red() { awk '$1 !~ /^#/ && ($3 == "cifs" || $3 == "smb3" || $3 == "nfs" || $3 == "nfs4") && $4 !~ /noauto/ {print $2}' /etc/fstab 2>/dev/null; }
caidas() { de_red | while read -r p; do mountpoint -q "$p" || echo "$p"; done; }

case ${1:-} in
diagnosticar)
  [ -n "$(de_red)" ] || { echo "Este equipo no tiene unidades de red configuradas; soporte tiene que agregarlas."; exit 1; }
  c=$(caidas)
  [ -n "$c" ] || { echo "Todas las unidades de red están conectadas: $(de_red | paste -sd, | sed 's/,/, /g')."; exit 10; }
  echo "Estas unidades de red no están conectadas: $(echo "$c" | paste -sd, | sed 's/,/, /g')."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para montar unidades de red."; exit 3; }
  exit 0 ;;
aplicar)
  caidas | while read -r p; do timeout 30 mount "$p" 2>/dev/null; done
  echo "Volví a conectar las unidades de red."
  exit 0 ;;
verificar)
  c=$(caidas)
  [ -z "$c" ] || { echo "No se pudieron conectar: $(echo "$c" | paste -sd, | sed 's/,/, /g'). Puede que el servidor no responda."; exit 1; }
  echo "Todas las unidades de red están conectadas."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
