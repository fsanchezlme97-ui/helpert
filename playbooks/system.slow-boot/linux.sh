#!/bin/bash
# Ver por qué el equipo arranca lento: duración del último arranque (systemd), los servicios que más tardaron y los
# que hicieron esperar al apagar la vez anterior. Solo lectura: termina con 10.
set -u
legible() { sed -E 's/\.[0-9]+//g; s/min/ min/; s/([0-9])s$/\1 s/'; }  # «1min 2.345s» -> «1 min 2 s»

case ${1:-} in
diagnosticar)
  command -v systemd-analyze >/dev/null || { echo "No puedo medir el arranque en este equipo (no usa systemd)."; exit 1; }
  # microsegundos: antes del sistema (BIOS y cargador) + desde que arranca el núcleo hasta terminar
  bios=$(systemctl show -p FirmwareTimestampMonotonic --value 2>/dev/null); bios=${bios:-0}
  fin=$(systemctl show -p FinishTimestampMonotonic --value 2>/dev/null); fin=${fin:-0}
  [ "$fin" -gt 0 ] 2>/dev/null || { echo "El equipo todavía está terminando de arrancar. Vuelve a pedirlo en un par de minutos."; exit 10; }
  total=$(( (bios + fin) / 1000000 ))
  if [ "$total" -ge 60 ]; then echo "El último arranque tardó $((total / 60)) min $((total % 60)) s: es más lento de lo normal."
  else echo "El último arranque tardó $total s, que es normal."; fi
  [ $(( bios / 1000000 )) -ge 15 ] && echo "De eso, $(( bios / 1000000 )) s fueron antes de Linux (la BIOS del equipo o el menú de arranque)."
  # lo que más tardó (1 s o más), sin decimales
  lentos=$(systemd-analyze blame --no-pager 2>/dev/null | awk '{u = $NF; $NF = ""; sub(/ +$/, ""); sub(/^ +/, "")} u != "" && ($0 ~ /min/ || $0 ~ /[0-9]s$/) {print u "\t" $0}' | head -3)
  if [ -n "$lentos" ]; then
    echo "Lo que más tardó al arrancar:"
    printf '%s\n' "$lentos" | while IFS=$'\t' read -r u t; do echo "- ${u%.service}: $(echo "$t" | legible)"; done
    echo "$lentos" | grep -q 'wait-online' && echo "Parte de la espera es el equipo esperando a la red; si arranca sin cable o sin Wi-Fi, tarda más."
  fi
  # apagado anterior: servicios que no se detuvieron a tiempo (el sistema los esperó y luego los cerró a la fuerza)
  if command -v journalctl >/dev/null; then
    apagado=$(journalctl -b -1 -q --no-pager -o cat _PID=1 2>/dev/null | grep -E "State 'stop-sigterm' timed out|Stopping timed out" |
              cut -d: -f1 | sed 's/\.service$//' | sort -u | head -3 | paste -sd, | sed 's/,/, /g')
    [ -n "$apagado" ] && echo "Al apagarse la última vez, tuvo que esperar a: $apagado. Si pasa siempre, avisa a soporte."
  fi
  [ "$total" -ge 60 ] && echo "Si quieres que lo revise un técnico, pásale este resumen."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
