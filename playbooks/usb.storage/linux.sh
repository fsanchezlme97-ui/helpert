#!/bin/bash
# Abrir una memoria USB o disco externo: si el equipo lo detecta pero no está montado, lo monta para la persona
# con udisksctl (igual que al conectarla en el escritorio). Nunca formatea ni repara.
set -u
usuario=${HP_USUARIO:-}
# particiones con sistema de archivos de discos extraíbles o USB, sin montar
sin_montar() { lsblk -rpno NAME,TYPE,FSTYPE,MOUNTPOINT,RM,TRAN 2>/dev/null | awk -F'[ ]' '($5 == 1 || $6 == "usb") && $3 != "" && $4 == "" && $2 == "part" || ($2 == "disk" && $3 != "" && $4 == "" && ($5 == 1 || $6 == "usb")) {print $1}'; }
extraibles() { lsblk -rdpno NAME,RM,TRAN,SIZE,MODEL 2>/dev/null | awk -F'[ ]' '$2 == 1 || $3 == "usb"'; }
como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }

case ${1:-} in
diagnosticar)
  e=$(extraibles)
  [ -n "$e" ] || { echo "El equipo no detecta ninguna memoria USB ni disco externo. Desconéctala, espera 5 segundos y conéctala en otro puerto; si sigue sin aparecer, puede estar dañada."; exit 10; }
  s=$(sin_montar)
  [ -n "$s" ] || { echo "La memoria está conectada y abierta: búscala en el explorador de archivos, en la barra lateral."; exit 10; }
  echo "El equipo detecta la memoria, pero no está abierta."
  exit 0 ;;
comprobar)
  { [ -n "$usuario" ] && [ "$usuario" != root ]; } || { echo "No sé qué persona lo pide."; exit 3; }
  command -v udisksctl >/dev/null || { echo "Este equipo no tiene udisks para abrir memorias."; exit 3; }
  exit 0 ;;
aplicar)
  for d in $(sin_montar); do como udisksctl mount --no-user-interaction -b "$d" 2>&1 | sed 's/^Mounted .* at /- Abierta en /'; done
  exit 0 ;;
verificar)
  [ -z "$(sin_montar)" ] || { echo "No pude abrir la memoria: puede tener un formato que el equipo no lee o estar dañada."; exit 1; }
  echo "La memoria está abierta: búscala en el explorador de archivos."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
