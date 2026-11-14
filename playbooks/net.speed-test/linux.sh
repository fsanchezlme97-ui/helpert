#!/bin/bash
# Medir la velocidad de internet: latencia al router (red local o Wi-Fi) y a internet (1.1.1.1), una descarga acotada
# de Cloudflare (hasta 25 MB o 15 s) y lo ocupado que está el equipo. Solo mide: termina con 10.
set -u
URL='https://speed.cloudflare.com/__down?bytes=25000000'
# «promedio_ms pérdida_%» de 4 pings; nada si no responde ninguno (hay routers y redes que no contestan pings)
latencia() {
  ping -c 4 -W 2 -q "$1" 2>/dev/null | awk '
    /packet loss/ {for (i = 1; i <= NF; i++) if ($i ~ /%$/) {p = $i; sub(/%/, "", p)}}
    /min\/avg/ {split($0, a, "="); split(a[2], b, "/"); m = b[2]}
    END {if (m != "") printf "%d %d\n", m + 0.5, p}'
}
mayor() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a > b)}'; }

case ${1:-} in
diagnosticar)
  dev=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  gw=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}')
  [ -n "$gw$dev" ] || { echo "El equipo no está conectado a ninguna red: no hay nada que medir. Prueba «Sin internet o Wi-Fi»."; exit 10; }
  wifi=0; [ -d "/sys/class/net/$dev/wireless" ] && wifi=1
  gms= gpe=; [ -n "$gw" ] && read -r gms gpe <<< "$(latencia "$gw")"
  read -r ims ipe <<< "$(latencia 1.1.1.1)"
  mbps=; falta="el equipo no llega al servidor de prueba (puede ser un bloqueo o un proxy de la empresa)"
  if ! command -v curl >/dev/null; then falta="falta la herramienta curl en este equipo"; else
    v=$(curl -s -o /dev/null --connect-timeout 5 --max-time 15 -w '%{speed_download}' "$URL" 2>/dev/null)
    mbps=$(awk -v v="${v:-0}" 'BEGIN {if (v > 0) printf "%.1f", v * 8 / 1000000}')
  fi
  carga=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null); nucleos=$(nproc 2>/dev/null)

  # el veredicto primero: equipo, red local (Wi-Fi o cable) o la conexión a internet
  if mayor "${carga:-0}" "${nucleos:-1}"; then
    echo "Parece del equipo: está muy ocupado y eso hace que todo, también internet, vaya lento. Cierra los programas que no uses o reinícialo."
  elif [ -n "${gms:-}" ] && { [ "$gms" -gt 30 ] || [ "${gpe:-0}" -gt 0 ]; }; then
    if [ "$wifi" = 1 ]; then echo "Parece del Wi-Fi: la conexión con el router es lenta o pierde datos. Acércate al router o, si puedes, usa un cable."
    else echo "Parece de la red local: la conexión con el router es lenta o pierde datos. Puede ser el cable, el punto de red o el router: lo revisa soporte."; fi
  elif [ -z "$mbps" ]; then
    echo "No pude medir la velocidad de descarga: el equipo no llega al servidor de prueba (puede ser un bloqueo o un proxy de la empresa)."
  elif mayor 5 "$mbps" || { [ -n "${ims:-}" ] && { [ "$ims" -gt 150 ] || [ "${ipe:-0}" -gt 0 ]; }; }; then
    echo "Parece de la conexión a internet: tu equipo y la red local responden bien, pero la salida a internet es lenta. Si sigue así, avisa a soporte para que lo revise con el proveedor."
  else
    echo "La conexión va bien: no veo nada lento en el equipo, la red local ni internet."
  fi
  [ -n "$mbps" ] && echo "Velocidad de descarga: $mbps Mbps."
  if [ -n "${gms:-}" ]; then echo "Tiempo de respuesta del router: $gms ms (pérdida ${gpe:-0} %)."; else echo "El router no contesta a la prueba de respuesta (algunos no lo hacen)."; fi
  [ -n "${ims:-}" ] && echo "Tiempo de respuesta de internet: $ims ms (pérdida ${ipe:-0} %)."
  [ "$wifi" = 1 ] && echo "Estás conectado por Wi-Fi."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
