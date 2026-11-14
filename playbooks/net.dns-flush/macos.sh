#!/bin/bash
# Limpiar la caché de nombres (DNS) de macOS: dscacheutil y mDNSResponder. No reinicia la red.
set -u
con_limite() {  # macOS no trae timeout: corta la orden a los $1 segundos
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; kill "$p" ) >/dev/null 2>&1 &
  local w=$!
  wait "$p"; local r=$?
  kill "$w" 2>/dev/null
  return $r
}
resuelve() { con_limite 8 dscacheutil -q host -a name example.com 2>/dev/null | grep -q 'address:'; }

case ${1:-} in
diagnosticar)
  echo "Puedo borrar la caché de nombres del equipo."
  echo "Así el equipo vuelve a preguntar la dirección de cada página o sistema. No corta la red."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para borrar la caché de nombres."; exit 3; }
  exit 0 ;;
aplicar)
  dscacheutil -flushcache 2>/dev/null
  killall -HUP mDNSResponder 2>/dev/null || { echo "No pude borrar la caché de nombres."; exit 1; }
  echo "Borré la caché de nombres. Cierra y vuelve a abrir el navegador para que también olvide las direcciones viejas."
  exit 0 ;;
verificar)
  sleep 1
  pgrep -x mDNSResponder >/dev/null || { echo "El servicio de nombres del equipo no está funcionando: reinicia el equipo."; exit 1; }
  resuelve || { echo "Borré la caché, pero los nombres de dominio no se resuelven: prueba «Sin internet o Wi-Fi»."; exit 1; }
  echo "La caché de nombres está limpia y el equipo resuelve bien los nombres de dominio."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
