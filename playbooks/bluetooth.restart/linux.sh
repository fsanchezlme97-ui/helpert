#!/bin/bash
# Reactivar el Bluetooth (BlueZ): rfkill, servicio bluetooth y encendido del adaptador.
set -u
encendido() { timeout 5 bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; }
bloqueado() { rfkill list bluetooth 2>/dev/null | grep -q 'blocked: yes'; }

case ${1:-} in
diagnosticar)
  command -v bluetoothctl >/dev/null || { echo "Este equipo no tiene las herramientas de Bluetooth instaladas."; exit 1; }
  rfkill list bluetooth 2>/dev/null | grep -q . || [ -d /sys/class/bluetooth ] || { echo "No encontré un adaptador Bluetooth en este equipo."; exit 1; }
  if ! bloqueado && systemctl is-active -q bluetooth && encendido; then echo "El Bluetooth está encendido y el servicio funciona."; exit 10; fi
  bloqueado && echo "El Bluetooth está bloqueado (modo avión o interruptor)."
  systemctl is-active -q bluetooth || echo "El servicio de Bluetooth está detenido."
  encendido || echo "El adaptador Bluetooth está apagado."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el Bluetooth."; exit 3; }
  exit 0 ;;
aplicar)
  rfkill unblock bluetooth 2>/dev/null
  systemctl restart bluetooth || { echo "No se pudo reiniciar el servicio de Bluetooth."; exit 1; }
  sleep 2
  timeout 10 bluetoothctl power on >/dev/null 2>&1
  echo "Desbloqueé el Bluetooth, reinicié su servicio y lo encendí."
  exit 0 ;;
verificar)
  for _ in 1 2 3 4 5; do encendido && break; sleep 1; done
  encendido || { echo "El Bluetooth sigue apagado."; exit 1; }
  echo "El Bluetooth está encendido. Si tu dispositivo no se conecta solo, apágalo y vuelve a encenderlo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
