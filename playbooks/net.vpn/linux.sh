#!/bin/bash
# Conectar la VPN (NetworkManager: vpn y wireguard). Conecta la indicada en HP_VPN o la primera configurada.
set -u
vpn=${HP_VPN:-}
vpns() { nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 == "vpn" || $2 == "wireguard" {print $1}'; }
activas() { nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2 == "vpn" || $2 == "wireguard" {print $1}'; }
elegida() { if [ -n "$vpn" ]; then vpns | grep -ixF -- "$vpn" | head -1; else vpns | head -1; fi; }

case ${1:-} in
diagnosticar)
  command -v nmcli >/dev/null || { echo "Este equipo no usa NetworkManager."; exit 1; }
  [ -n "$(vpns)" ] || { echo "Este equipo no tiene ninguna VPN configurada; soporte tiene que configurarla."; exit 1; }
  a=$(activas)
  if [ -n "$a" ] && { [ -z "$vpn" ] || echo "$a" | grep -qixF -- "$vpn"; }; then echo "La VPN «$(echo "$a" | head -1)» ya está conectada."; exit 10; fi
  e=$(elegida)
  [ -n "$e" ] || { echo "No encontré la VPN «$vpn». Las configuradas son: $(vpns | paste -sd, | sed 's/,/, /g')."; exit 1; }
  echo "La VPN «$e» está desconectada."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para conectar la VPN."; exit 3; }
  nmcli networking connectivity check | grep -qE 'full|limited' || { echo "Primero hace falta internet: el equipo no tiene conexión."; exit 3; }
  exit 0 ;;
aplicar)
  e=$(elegida)
  nmcli connection up id "$e" >/dev/null 2>&1 || { echo "La VPN «$e» no conectó: puede pedir una contraseña o un código que solo tú tienes."; exit 1; }
  echo "Conecté la VPN «$e»."
  exit 0 ;;
verificar)
  e=$(elegida)
  activas | grep -qxF -- "$e" || { echo "La VPN «$e» sigue desconectada."; exit 1; }
  echo "La VPN «$e» está conectada."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
