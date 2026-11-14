#!/bin/bash
# Revisar el cable de red (macOS): si el puerto detecta el cable (status de ifconfig), a qué velocidad (media) y si
# recibió dirección IP. Solo revisa: termina con 10.
set -u
# puertos de red con cable: los de networksetup que no son Wi-Fi, Bluetooth, puente Thunderbolt ni iPhone/iPad
puertos() {
  networksetup -listallhardwareports 2>/dev/null | awk '
    /^Hardware Port:/ {n = $0; sub(/^Hardware Port: /, "", n)}
    /^Device:/ {if (n !~ /Wi-Fi|AirPort|Bluetooth|Thunderbolt Bridge|^Thunderbolt [0-9]|iPhone|iPad|VPN/) print $2}'
}
TECNICO="Si sigue igual, el cable o el punto de red lo revisa un técnico."

case ${1:-} in
diagnosticar)
  lista=$(puertos)
  [ -n "$lista" ] || { echo "Este equipo no tiene puerto de red con cable (o el adaptador de red USB o el dock no está conectado)."; exit 10; }
  p=
  for x in $lista; do ifconfig "$x" 2>/dev/null | grep -q 'status: active' && { p=$x; break; }; done
  if [ -z "$p" ]; then
    echo "El puerto de red no detecta el cable."
    echo "Revisa que el cable esté bien encajado en el equipo (o en el adaptador) y en la pared o el router, y que se encienda la luz del puerto."
    echo "Prueba con otro cable o en otro punto de red. $TECNICO"
    exit 10
  fi
  media=$(ifconfig "$p" 2>/dev/null | awk '/media:/ {print; exit}')
  v=$(echo "$media" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)base.*/\1/p')  # «media: autoselect (1000baseT <full-duplex>)»
  vel=; [ -n "$v" ] && vel=" a $v Mb/s"
  a=$(ipconfig getifaddr "$p" 2>/dev/null)
  case $a in
  '') echo "El puerto detecta el cable$vel, pero el equipo no recibió dirección IP del router."; echo "Prueba «Renovar la dirección IP». Si sigue igual, lo revisa soporte." ;;
  169.254.*) echo "El puerto detecta el cable$vel, pero el router no le dio una dirección al equipo ($a)."; echo "Prueba «Renovar la dirección IP». Si sigue igual, lo revisa soporte." ;;
  *) echo "El cable está bien: el puerto lo detecta$vel y el equipo recibió la dirección $a." ;;
  esac
  case $v in
  10) echo "Ojo: 10 Mb/s es muy poco; suele ser un cable o un punto de red dañado. $TECNICO" ;;
  100) echo "Ojo: 100 Mb/s funciona, pero si en la oficina suele ir a 1000 Mb/s, el cable puede estar dañado." ;;
  esac
  echo "$media" | grep -q 'half-duplex' && echo "Además, la conexión va en modo «half duplex», señal típica de un cable o punto de red con problemas."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
