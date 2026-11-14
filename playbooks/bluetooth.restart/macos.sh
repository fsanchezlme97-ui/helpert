#!/bin/bash
# Reactivar el Bluetooth en macOS: reinicia bluetoothd (el servicio de Bluetooth; launchd lo vuelve a arrancar solo) y
# revisa si quedó encendido. macOS no trae una orden para encenderlo (blueutil no viene con el sistema) ni tiene un
# bloqueo de radio como Linux: si sigue apagado, se le pide a la persona que lo encienda. Compatible con bash 3.2.
set -u
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
# «on», «off» o nada si no hay adaptador (macOS 13+ dice «State: On»; antes, «Bluetooth Power: On»)
estado() { tope 12 system_profiler SPBluetoothDataType 2>/dev/null | awk -F': ' '/^ *(State|Bluetooth Power): /{print tolower($2); exit}'; }
corre() { pgrep -x bluetoothd >/dev/null; }

case ${1:-} in
diagnosticar)
  e=$(estado)
  [ -n "$e" ] || { echo "No encontré un adaptador Bluetooth en este equipo."; exit 1; }
  if [ "$e" = on ] && corre; then echo "El Bluetooth está encendido y el servicio funciona."; exit 10; fi
  corre || echo "El servicio de Bluetooth está detenido."
  [ "$e" = on ] || echo "El Bluetooth está apagado."
  echo "Voy a reiniciar el servicio de Bluetooth: tu teclado, mouse o audífonos Bluetooth se desconectarán unos segundos."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el Bluetooth."; exit 3; }
  [ -n "$(estado)" ] || { echo "No encontré un adaptador Bluetooth en este equipo."; exit 3; }
  exit 0 ;;
aplicar)
  antes=$(pgrep -x bluetoothd)
  pkill -x bluetoothd 2>/dev/null
  # espera a que launchd lo arranque de nuevo (otro proceso, no el que se estaba cerrando)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1; ahora=$(pgrep -x bluetoothd)
    [ -n "$ahora" ] && [ "$ahora" != "$antes" ] && break
  done
  ahora=$(pgrep -x bluetoothd)
  { [ -n "$ahora" ] && [ "$ahora" != "$antes" ]; } || { echo "No se pudo reiniciar el servicio de Bluetooth."; exit 1; }
  echo "Reinicié el servicio de Bluetooth."
  exit 0 ;;
verificar)
  for _ in 1 2 3; do e=$(estado); [ "$e" = on ] && corre && break; sleep 2; done
  { [ "$e" = on ] && corre; } || { echo "El Bluetooth sigue apagado: enciéndelo en el Centro de control o en Ajustes del Sistema > Bluetooth. Si no enciende, reinicia el equipo; si sigue igual, avisa a soporte."; exit 1; }
  echo "El Bluetooth está encendido. Si tu dispositivo no se conecta solo, apágalo y vuelve a encenderlo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
