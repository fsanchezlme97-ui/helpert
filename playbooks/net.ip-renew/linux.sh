#!/bin/bash
# Renovar la dirección IP (NetworkManager): vuelve a activar la conexión de cable o Wi-Fi para que pida una dirección
# nueva al router (DHCP). Nunca toca una conexión con IP fija. Ojo: aplicar corta la red unos segundos.
set -u
# la interfaz de cable o Wi-Fi conectada (o conectándose); primero la de la ruta por defecto
dispositivo() {
  local r; r=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | awk -F: -v r="$r" '
    ($2 == "ethernet" || $2 == "wifi") && $3 ~ /^connect/ {if ($1 == r) {print $1; f = 1; exit} if (p == "") p = $1}
    END {if (!f && p != "") print p}'
}
conexion() { nmcli -g GENERAL.CON-UUID device show "$1" 2>/dev/null; }
metodo() { [ -n "$1" ] && nmcli -g ipv4.method connection show "$1" 2>/dev/null; }  # auto = DHCP, manual = IP fija
nombre() { [ "$(nmcli -g GENERAL.TYPE device show "$1" 2>/dev/null)" = wifi ] && echo "el Wi-Fi" || echo "la conexión por cable"; }
# la dirección IPv4 de la interfaz; una 169.254 solo si no tiene otra
ipv4() {
  ip -4 -o addr show dev "$1" 2>/dev/null | awk '{sub(/\/.*/, "", $4); if ($4 !~ /^169\.254\./) {print $4; f = 1; exit} if (l == "") l = $4}
    END {if (!f && l != "") print l}'
}
puerta() { ip -4 route show default dev "$1" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}'; }
# la contraseña del Wi-Fi guardada en la sesión de la persona (no en el equipo): al reactivar como root podría no tenerla
secreto() {
  local x
  for x in 802-11-wireless-security.psk-flags 802-1x.password-flags; do nmcli -g "$x" connection show "$1" 2>/dev/null; done |
    grep -qE '^[1-9]|agent|not-saved'
}
valida() { [ -n "$1" ] && case $1 in 169.254.*) false ;; *) true ;; esac; }
# deja en $d y $u la interfaz y su conexión, o explica por qué no se puede
elegir() {
  command -v nmcli >/dev/null || { echo "Este equipo no usa NetworkManager: no sé renovar su dirección IP."; return 1; }
  d=$(dispositivo); u=$(conexion "${d:-x}")
  [ -n "$d" ] && [ -n "$u" ] || { echo "No hay ninguna conexión de red activa: conecta primero el cable o el Wi-Fi."; return 1; }
  case $(metodo "$u") in
  auto) ! secreto "$u" || { echo "La contraseña de esta red Wi-Fi está guardada solo en tu sesión: desconéctate y vuelve a conectarte desde el icono de red, que es lo mismo."; return 1; } ;;
  manual) echo "Este equipo usa una IP fija en $(nombre "$d"): renovarla no sirve. Si hay un problema con esa dirección, lo revisa soporte."; return 1 ;;
  *) echo "La conexión no está configurada para pedir su dirección al router: lo revisa soporte."; return 1 ;;
  esac
}

case ${1:-} in
diagnosticar)
  elegir || exit 3
  a=$(ipv4 "$d"); g=$(puerta "$d"); que=$(nombre "$d")
  if [ -z "$a" ]; then echo "Tu equipo no tiene dirección IP en $que: puedo pedirle una nueva al router."; echo "La red se corta unos segundos mientras tanto."; exit 0; fi
  if ! valida "$a"; then
    echo "Tu dirección IP es $a: el router no le dio una dirección al equipo. Puedo pedirle una nueva."
    echo "La red se corta unos segundos mientras tanto."
    exit 0
  fi
  if [ -n "$g" ] && ping -c 2 -W 2 -q "$g" >/dev/null 2>&1; then
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
  elegir || exit 1  # se vuelve a mirar: nunca se toca una IP fija
  nmcli -w 40 connection up uuid "$u" >/dev/null 2>&1 || { echo "Pedí una dirección nueva, pero el router no respondió. Si sigue igual, lo revisa soporte."; exit 1; }
  for _ in $(seq 10); do valida "$(ipv4 "$d")" && break; sleep 1; done
  a=$(ipv4 "$d")
  echo "Pedí una dirección IP nueva al router${a:+. Ahora es $a}."
  exit 0 ;;
verificar)
  d=$(dispositivo); a=$(ipv4 "${d:-x}")
  valida "$a" || { echo "El equipo sigue sin una dirección IP válida${a:+ ($a)}: el router no responde. Lo revisa soporte."; exit 1; }
  echo "El equipo tiene la dirección IP $a."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
