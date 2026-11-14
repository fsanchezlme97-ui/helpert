#!/bin/bash
# Revisar la cámara: si existe el dispositivo y qué programa lo tiene abierto. Solo lectura: termina con 10.
set -u
case ${1:-} in
diagnosticar)
  camaras=$(ls /dev/video* 2>/dev/null)
  if [ -z "$camaras" ]; then
    echo "El equipo no detecta ninguna cámara. Si es externa, desconéctala y conéctala en otro puerto; si es de la laptop, revisa que no tenga una tapa o una tecla de cámara apagada."
    exit 10
  fi
  nombre=$(cat /sys/class/video4linux/video0/name 2>/dev/null)
  echo "El equipo detecta la cámara${nombre:+ «$nombre»}."
  usando=$(for c in $camaras; do fuser "$c" 2>/dev/null; done | tr ' ' '\n' | grep -o '[0-9]*' | sort -u |
           while read -r p; do ps -o comm= -p "$p"; done | sort -u | paste -sd, | sed 's/,/, /g')
  if [ -n "$usando" ]; then echo "Ahora la está usando: $usando. Cierra ese programa y vuelve a abrir la videollamada."
  else echo "Ningún programa la está usando. En la videollamada, elige esta cámara en la configuración de video y dale permiso si lo pide."; fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
