#!/bin/bash
# Revisar el cable de red: si el puerto detecta el cable (carrier), a qué velocidad y si recibió dirección IP.
# Se leen los datos del kernel (/sys/class/net). Solo revisa: termina con 10.
set -u
# puertos de red con cable: interfaces físicas (con dispositivo) de tipo Ethernet que no son Wi-Fi
puertos() {
  local d
  for d in /sys/class/net/*; do
    [ -e "$d/device" ] && [ ! -e "$d/wireless" ] && [ ! -e "$d/phy80211" ] && [ "$(cat "$d/type" 2>/dev/null)" = 1 ] && echo "${d##*/}"
  done
}
dato() { cat "/sys/class/net/$1/$2" 2>/dev/null; }
ipv4() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}'; }
TECNICO="Si sigue igual, el cable o el punto de red lo revisa un técnico."

case ${1:-} in
diagnosticar)
  lista=$(puertos)
  [ -n "$lista" ] || { echo "Este equipo no tiene puerto de red con cable (o el adaptador de red USB no está conectado)."; exit 10; }
  p=
  for x in $lista; do [ "$(dato "$x" carrier)" = 1 ] && { p=$x; break; }; done
  if [ -z "$p" ]; then
    p=${lista%%[[:space:]]*}
    if ! ip -o link show dev "$p" 2>/dev/null | grep -q '[<,]UP[,>]'; then
      echo "El puerto de red con cable está desactivado en el equipo: lo activa soporte."; exit 10
    fi
    echo "El puerto de red no detecta el cable."
    echo "Revisa que el cable esté bien encajado en el equipo y en la pared o el router (debe hacer clic) y que se encienda la luz del puerto."
    echo "Prueba con otro cable o en otro punto de red. $TECNICO"
    exit 10
  fi
  v=$(dato "$p" speed); dx=$(dato "$p" duplex); a=$(ipv4 "$p")
  case ${v:-} in ''|-*) vel="" ;; *) vel=" a $v Mb/s" ;; esac
  case $a in
  '') echo "El puerto detecta el cable$vel, pero el equipo no recibió dirección IP del router."; echo "Prueba «Renovar la dirección IP». Si sigue igual, lo revisa soporte." ;;
  169.254.*) echo "El puerto detecta el cable$vel, pero el router no le dio una dirección al equipo ($a)."; echo "Prueba «Renovar la dirección IP». Si sigue igual, lo revisa soporte." ;;
  *) echo "El cable está bien: el puerto lo detecta$vel y el equipo recibió la dirección $a." ;;
  esac
  case ${v:-} in
  10) echo "Ojo: 10 Mb/s es muy poco; suele ser un cable o un punto de red dañado. $TECNICO" ;;
  100) echo "Ojo: 100 Mb/s funciona, pero si en la oficina suele ir a 1000 Mb/s, el cable puede estar dañado." ;;
  esac
  [ "$dx" = half ] && echo "Además, la conexión va en modo «half duplex», señal típica de un cable o punto de red con problemas."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
