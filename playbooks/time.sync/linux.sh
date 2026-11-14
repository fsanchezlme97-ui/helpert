#!/bin/bash
# Corregir la hora: activa NTP (systemd-timesyncd o chrony, lo que use el equipo) y espera la sincronización.
set -u
sincronizada() { [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; }

case ${1:-} in
diagnosticar)
  command -v timedatectl >/dev/null || { echo "No puedo revisar la hora en este equipo."; exit 1; }
  sincronizada && { echo "La hora del equipo está sincronizada por internet: $(date '+%d/%m/%Y %H:%M')."; exit 10; }
  [ "$(timedatectl show -p NTP --value)" = yes ] || echo "La hora automática está desactivada."
  echo "La hora del equipo no está sincronizada (ahora marca $(date '+%d/%m/%Y %H:%M'))."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para ajustar la hora."; exit 3; }
  exit 0 ;;
aplicar)
  timedatectl set-ntp true || { echo "No se pudo activar la hora automática."; exit 1; }
  for s in systemd-timesyncd chronyd chrony; do systemctl is-enabled -q "$s" 2>/dev/null && systemctl restart "$s"; done
  for _ in $(seq 30); do sincronizada && break; sleep 1; done
  echo "Activé la hora automática y pedí sincronizarla."
  exit 0 ;;
verificar)
  sincronizada || { echo "La hora todavía no se sincroniza; puede que la red bloquee el servicio de hora."; exit 1; }
  echo "La hora está sincronizada: $(date '+%d/%m/%Y %H:%M')."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
