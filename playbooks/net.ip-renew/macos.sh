#!/bin/bash
# Renovar la dirección IP (DHCP) en macOS: vuelve a pedirle una dirección al router por la interfaz de cable o Wi-Fi.
# Nunca toca un servicio de red con IP fija. Ojo: aplicar corta la red unos segundos.
set -u
# la interfaz de la ruta por defecto (si no es una VPN); si no hay, la primera de cable o Wi-Fi activa
dispositivo() {
  local d; d=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
  case $d in utun*|ppp*|ipsec*|gif*|stf*) d= ;; esac
  [ -n "$d" ] && { echo "$d"; return; }
  for d in $(networksetup -listallhardwareports 2>/dev/null | awk '/^Device:/ {print $2}'); do
    ifconfig "$d" 2>/dev/null | grep -q 'status: active' && { echo "$d"; return; }
  done
}
# el servicio de red (como en Ajustes: «Wi-Fi», «Ethernet»…) de la interfaz
servicio() {
  networksetup -listnetworkserviceorder 2>/dev/null | awk -v d="$1" '
    /^\([0-9*]+\) / {s = $0; sub(/^\([0-9*]+\) /, "", s)} index($0, "Device: " d ")") {print s; exit}'
}
dhcp() { [ "$(networksetup -getinfo "$1" 2>/dev/null | head -1)" = "DHCP Configuration" ]; }
ipv4() { ipconfig getifaddr "$1" 2>/dev/null; }
valida() { [ -n "$1" ] && case $1 in 169.254.*) false ;; *) true ;; esac; }
# deja en $d y $s la interfaz y su servicio, o explica por qué no se puede
elegir() {
  d=$(dispositivo); s=
  [ -n "$d" ] && s=$(servicio "$d")
  [ -n "$s" ] || { echo "No hay ninguna conexión de red activa: conecta primero el cable o el Wi-Fi."; return 1; }
  dhcp "$s" || { echo "Este equipo usa una IP fija en «${s}»: renovarla no sirve. Si hay un problema con esa dirección, lo revisa soporte."; return 1; }
}

case ${1:-} in
diagnosticar)
  elegir || exit 3
  a=$(ipv4 "$d"); g=$(ipconfig getoption "$d" router 2>/dev/null)
  if [ -z "$a" ]; then echo "Tu equipo no tiene dirección IP en «${s}»: puedo pedirle una nueva al router."; echo "La red se corta unos segundos mientras tanto."; exit 0; fi
  if ! valida "$a"; then
    echo "Tu dirección IP es $a: el router no le dio una dirección al equipo. Puedo pedirle una nueva."
    echo "La red se corta unos segundos mientras tanto."
    exit 0
  fi
  if [ -n "$g" ] && ping -c 2 -t 4 -q "$g" >/dev/null 2>&1; then
    echo "Tu dirección IP es $a y el router responde: renovarla no debería cambiar nada."; exit 10
  fi
  echo "Tu dirección IP es $a, pero el router${g:+ ($g)} no responde: puedo pedirle una dirección nueva."
  echo "La red se corta unos segundos mientras tanto."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para renovar la dirección IP."; exit 3; }
  elegir || exit 3
  exit 0 ;;
aplicar)
  elegir || exit 1  # se vuelve a mirar: nunca se le impone DHCP a una IP fija
  # el servicio ya usa DHCP: esto solo hace que vuelva a pedir la dirección
  ipconfig set "$d" DHCP 2>/dev/null || { echo "No pude pedir una dirección nueva al router."; exit 1; }
  for _ in $(seq 20); do valida "$(ipv4 "$d")" && break; sleep 1; done
  a=$(ipv4 "$d")
  valida "$a" || { echo "Pedí una dirección nueva, pero el router no respondió. Si sigue igual, lo revisa soporte."; exit 1; }
  echo "Pedí una dirección IP nueva al router. Ahora es $a."
  exit 0 ;;
verificar)
  d=$(dispositivo); a=
  [ -n "$d" ] && a=$(ipv4 "$d")
  valida "$a" || { echo "El equipo sigue sin una dirección IP válida${a:+ ($a)}: el router no responde. Lo revisa soporte."; exit 1; }
  echo "El equipo tiene la dirección IP $a."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
