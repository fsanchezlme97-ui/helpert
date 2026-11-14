#!/bin/bash
# Conectar la VPN (macOS): las VPN de Ajustes del Sistema > VPN que macOS conoce (scutil --nc: IKEv2, L2TP, IPSec y las
# de apps que se registran ahí). Conecta la indicada en HP_VPN (sin distinguir mayúsculas; exacta o, si no, que la
# contenga) o la primera activada. Nunca pasa usuario ni contraseña: usa lo que el equipo tiene guardado.
# Las VPN que solo se manejan desde su propia app (y no aparecen en scutil) no se pueden conectar desde aquí.
set -u
vpn=${HP_VPN:-}
# «id|estado|nombre» de cada VPN activada; scutil escribe: * (Disconnected)   <id> <tipo> "<nombre>" [<tipo>]
lista() {
  scutil --nc list 2>/dev/null | awk '/^\* \(/ {
    e = $2; gsub(/[()]/, "", e); id = $3
    n = $0; sub(/^[^"]*"/, "", n); sub(/"[^"]*$/, "", n)
    print id "|" e "|" n }'
}
nombres() { lista | cut -d'|' -f3-; }
elegida() {  # la línea de la VPN pedida (exacta o, si no, la primera que la contenga) o de la primera
  [ -n "$vpn" ] || { lista | head -1; return; }
  lista | awk -F'|' -v v="$vpn" '{n = tolower(substr($0, length($1) + length($2) + 3)); v = tolower(v)}
    n == v {print; f = 1; exit} p == "" && index(n, v) {p = $0} END {if (!f && p != "") print p}'
}
estado() { scutil --nc status "$1" 2>/dev/null | head -1; }
nombre() { echo "$1" | cut -d'|' -f3-; }

case ${1:-} in
diagnosticar)
  command -v scutil >/dev/null || { echo "No puedo revisar las VPN en este equipo."; exit 1; }
  [ -n "$(lista)" ] || { echo "Este equipo no tiene ninguna VPN configurada en Ajustes del Sistema; si la VPN de la empresa es una app, ábrela y conéctate desde ella. Si no hay, soporte tiene que configurarla."; exit 1; }
  e=$(elegida)
  [ -n "$e" ] || { echo "No encontré la VPN «${vpn}». Las configuradas son: $(nombres | head -8 | paste -sd, - | sed 's/,/, /g')."; exit 1; }
  if [ "$(echo "$e" | cut -d'|' -f2)" = Connected ]; then echo "La VPN «$(nombre "$e")» ya está conectada."; exit 10; fi
  if [ -z "$vpn" ]; then
    a=$(lista | awk -F'|' '$2 == "Connected"' | head -1)
    [ -z "$a" ] || { echo "La VPN «$(nombre "$a")» ya está conectada."; exit 10; }
  fi
  echo "La VPN «$(nombre "$e")» está desconectada."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para conectar la VPN."; exit 3; }
  route -n get default >/dev/null 2>&1 || { echo "Primero hace falta internet: el equipo no tiene conexión."; exit 3; }
  [ -n "$(elegida)" ] || { echo "No encontré la VPN${vpn:+ «${vpn}»}."; exit 3; }
  exit 0 ;;
aplicar)
  e=$(elegida); id=$(echo "$e" | cut -d'|' -f1)
  [ -n "$id" ] || { echo "No encontré la VPN${vpn:+ «${vpn}»}."; exit 1; }
  scutil --nc start "$id" >/dev/null 2>&1 || { echo "La VPN «$(nombre "$e")» no conectó."; exit 1; }
  # start no espera: se mira el estado hasta 30 segundos
  fin=$((SECONDS + 30)); while [ "$SECONDS" -lt "$fin" ]; do [ "$(estado "$id")" = Connected ] && break; sleep 1; done
  [ "$(estado "$id")" = Connected ] || { echo "La VPN «$(nombre "$e")» no conectó: puede pedir una contraseña o un código que solo tú tienes. Si macOS te muestra una ventana para escribirla, hazlo ahí."; exit 1; }
  echo "Conecté la VPN «$(nombre "$e")»."
  exit 0 ;;
verificar)
  e=$(elegida); id=$(echo "$e" | cut -d'|' -f1)
  [ -n "$id" ] || { echo "No encontré la VPN${vpn:+ «${vpn}»}."; exit 1; }
  fin=$((SECONDS + 10)); while [ "$SECONDS" -lt "$fin" ]; do [ "$(estado "$id")" = Connected ] && break; sleep 1; done
  [ "$(estado "$id")" = Connected ] || { echo "La VPN «$(nombre "$e")» sigue desconectada."; exit 1; }
  echo "La VPN «$(nombre "$e")» está conectada."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
