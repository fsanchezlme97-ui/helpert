#!/bin/bash
# Sin internet o Wi-Fi (macOS): limpia la caché DNS (dscacheutil y mDNSResponder) y reinicia la red: apaga y enciende el
# Wi-Fi si estaba encendido y baja y sube los puertos de cable conectados (ifconfig, que no queda guardado). Nunca
# desactiva servicios de red en los ajustes: si se cortara a medias, quedarían apagados. La conectividad se prueba
# como lo hace macOS (captive.apple.com).
# Ojo: aplicar corta la red unos segundos. Solo sirve si el equipo aún llega al servidor de Helpert (red local).
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
conectividad() {
  curl -s --connect-timeout 3 --max-time 5 http://captive.apple.com/hotspot-detect.html 2>/dev/null | grep -q Success && { echo full; return; }
  [ -n "$(puerta)" ] && echo "sin internet" || echo "sin red"
}
dns_ok() { tope 5 dscacheutil -q host -a name example.com 2>/dev/null | grep -q 'address:'; }
puerta() { route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}'; }
wifi() { networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: (Wi-Fi|AirPort)/ {w = 1; next} /^Device:/ {if (w) {print $2; exit}}'; }
wifi_encendido() { networksetup -getairportpower "$1" 2>/dev/null | grep -q ': On'; }
# puertos de cable conectados: los de networksetup que no son Wi-Fi, Bluetooth, puente Thunderbolt ni iPhone/iPad
cables() {
  for d in $(networksetup -listallhardwareports 2>/dev/null | awk '
    /^Hardware Port:/ {n = $0; sub(/^Hardware Port: /, "", n)}
    /^Device:/ {if (n !~ /Wi-Fi|AirPort|Bluetooth|Thunderbolt Bridge|^Thunderbolt [0-9]|iPhone|iPad|VPN/) print $2}'); do
    ifconfig "$d" 2>/dev/null | grep -q 'status: active' && echo "$d"
  done
}

case ${1:-} in
diagnosticar)
  command -v networksetup >/dev/null || { echo "No puedo revisar la red en este equipo."; exit 1; }
  c=$(conectividad); g=$(puerta)
  if [ "$c" = full ] && dns_ok; then echo "La conexión a internet funciona y los nombres de dominio se resuelven."; exit 10; fi
  echo "Conectividad: ${c}. Puerta de enlace: ${g:-ninguna}."
  dns_ok || echo "Los nombres de dominio no se resuelven."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar la red."; exit 3; }
  w=$(wifi)
  { [ -n "$(cables)" ] || { [ -n "$w" ] && wifi_encendido "$w"; }; } || { echo "No hay ningún cable conectado ni Wi-Fi encendido que reiniciar (para encender el Wi-Fi está «Reconectar el Wi-Fi»)."; exit 3; }
  exit 0 ;;
aplicar)
  dscacheutil -flushcache 2>/dev/null
  killall -HUP mDNSResponder 2>/dev/null
  w=$(wifi); l=$(cables)
  for d in $l; do ifconfig "$d" down 2>/dev/null; done
  if [ -n "$w" ] && wifi_encendido "$w"; then
    networksetup -setairportpower "$w" off 2>/dev/null; sleep 2; networksetup -setairportpower "$w" on 2>/dev/null
  else sleep 2; fi
  for d in $l; do ifconfig "$d" up 2>/dev/null; done
  fin=$((SECONDS + 30)); while [ "$SECONDS" -lt "$fin" ]; do [ "$(conectividad)" = full ] && break; sleep 1; done
  echo "Limpié la caché DNS y reinicié la red."
  exit 0 ;;
verificar)
  fin=$((SECONDS + 15)); while [ "$SECONDS" -lt "$fin" ]; do [ "$(conectividad)" = full ] && dns_ok && break; sleep 1; done
  [ "$(conectividad)" = full ] && dns_ok || { echo "Sigue sin haber conexión a internet."; exit 1; }
  echo "La conexión a internet volvió."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
