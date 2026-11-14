#!/bin/bash
# Reconectar el Wi-Fi (macOS): enciende la tarjeta Wi-Fi (networksetup -setairportpower; macOS no tiene modo avión ni
# bloqueo de radio) y espera a que se una sola a una red guardada; si estaba encendida sin conectar, la apaga y la
# enciende para que vuelva a buscarlas. «Conectado» es enlace activo y dirección IP: desde macOS 14 el nombre de la red
# puede venir oculto por privacidad, así que solo se muestra si se puede leer.
set -u
tarjeta() { networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: (Wi-Fi|AirPort)/ {w = 1; next} /^Device:/ {if (w) {print $2; exit}}'; }
encendida() { networksetup -getairportpower "$1" 2>/dev/null | grep -q ': On'; }
conectada() {
  ifconfig "$1" 2>/dev/null | grep -q 'status: active' || return 1
  a=$(ipconfig getifaddr "$1" 2>/dev/null)
  [ -n "$a" ] && case $a in 169.254.*) false ;; *) true ;; esac
}
guardadas() { networksetup -listpreferredwirelessnetworks "$1" 2>/dev/null | sed -n 's/^[[:space:]][[:space:]]*//p'; }
red() {  # el nombre de la red, si macOS lo deja leer
  n=$(networksetup -getairportnetwork "$1" 2>/dev/null | sed -n 's/^Current Wi-Fi Network: //p')
  [ -n "$n" ] || n=$(ipconfig getsummary "$1" 2>/dev/null | awk -F' : ' '$1 ~ /^ *SSID$/ {print $2; exit}')
  case $n in ''|*redacted*) ;; *) echo "$n" ;; esac
}
conectada_a() { n=$(red "$1"); if [ -n "$n" ]; then echo "El Wi-Fi está conectado a «${n}»."; else echo "El Wi-Fi está conectado a una red."; fi; }
esperar() { fin=$((SECONDS + $2)); while [ "$SECONDS" -lt "$fin" ]; do conectada "$1" && return 0; sleep 1; done; conectada "$1"; }

case ${1:-} in
diagnosticar)
  command -v networksetup >/dev/null || { echo "No puedo revisar la red en este equipo."; exit 1; }
  d=$(tarjeta)
  [ -n "$d" ] || { echo "No encontré una tarjeta Wi-Fi en este equipo."; exit 1; }
  if encendida "$d" && conectada "$d"; then conectada_a "$d"; exit 10; fi
  if encendida "$d"; then echo "El Wi-Fi está encendido, pero no está conectado a ninguna red."; else echo "El Wi-Fi está apagado."; fi
  [ -n "$(guardadas "$d")" ] || { echo "El equipo no tiene redes Wi-Fi guardadas: hace falta elegir la red y escribir su contraseña."; exit 10; }
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para encender el Wi-Fi."; exit 3; }
  [ -n "$(tarjeta)" ] || { echo "No encontré una tarjeta Wi-Fi."; exit 3; }
  exit 0 ;;
aplicar)
  d=$(tarjeta)
  [ -n "$d" ] || { echo "No encontré una tarjeta Wi-Fi."; exit 1; }
  if encendida "$d"; then
    conectada "$d" && { conectada_a "$d"; exit 0; }
    networksetup -setairportpower "$d" off 2>/dev/null; sleep 2
  fi
  networksetup -setairportpower "$d" on 2>/dev/null
  sleep 2
  encendida "$d" || { echo "No pude encender el Wi-Fi: enciéndelo en el icono del Wi-Fi de la barra de menús."; exit 1; }
  esperar "$d" 30
  echo "Encendí el Wi-Fi y le pedí conectarse a una red guardada."
  exit 0 ;;
verificar)
  d=$(tarjeta)
  { [ -n "$d" ] && esperar "$d" 5; } || { echo "El Wi-Fi está encendido, pero no se conectó a ninguna red guardada."; exit 1; }
  conectada_a "$d"
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
