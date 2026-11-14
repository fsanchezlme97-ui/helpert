#!/bin/bash
# Reconectar el Wi-Fi (NetworkManager): desbloquea la radio, la enciende y conecta la interfaz a una red guardada.
set -u
dispositivo() { nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}'; }
estado() { nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v d="$1" '$1 == d {print $2}'; }
bloqueado() { rfkill list wifi 2>/dev/null | grep -q 'blocked: yes'; }

case ${1:-} in
diagnosticar)
  command -v nmcli >/dev/null || { echo "Este equipo no usa NetworkManager."; exit 1; }
  d=$(dispositivo)
  [ -n "$d" ] || { echo "No encontré una tarjeta Wi-Fi en este equipo."; exit 1; }
  e=$(estado "$d")
  if [ "$e" = connected ] && ! bloqueado; then
    echo "El Wi-Fi está conectado a «$(nmcli -t -f GENERAL.CONNECTION device show "$d" | cut -d: -f2-)»."; exit 10
  fi
  bloqueado && echo "El Wi-Fi está bloqueado (modo avión o interruptor)."
  [ "$(nmcli radio wifi)" = enabled ] || echo "El Wi-Fi está apagado."
  echo "Estado de la tarjeta Wi-Fi: ${e:-desconocido}."
  guardadas=$(nmcli -t -f TYPE connection show | grep -c '802-11-wireless')
  [ "$guardadas" -gt 0 ] || { echo "El equipo no tiene redes Wi-Fi guardadas: hace falta elegir la red y escribir su contraseña."; exit 10; }
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para encender el Wi-Fi."; exit 3; }
  [ -n "$(dispositivo)" ] || { echo "No encontré una tarjeta Wi-Fi."; exit 3; }
  exit 0 ;;
aplicar)
  d=$(dispositivo)
  rfkill unblock wifi 2>/dev/null
  nmcli radio wifi on
  sleep 3
  nmcli device connect "$d" >/dev/null 2>&1 || nmcli device wifi rescan >/dev/null 2>&1
  for _ in $(seq 20); do [ "$(estado "$d")" = connected ] && break; sleep 1; done
  echo "Desbloqueé y encendí el Wi-Fi y pedí conectarlo a una red guardada."
  exit 0 ;;
verificar)
  d=$(dispositivo)
  [ "$(estado "$d")" = connected ] || { echo "El Wi-Fi está encendido, pero no se conectó a ninguna red guardada."; exit 1; }
  echo "El Wi-Fi está conectado a «$(nmcli -t -f GENERAL.CONNECTION device show "$d" | cut -d: -f2-)»."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
