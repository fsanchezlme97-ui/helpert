#!/bin/bash
# Revisar la señal del Wi-Fi (macOS): señal (dBm), banda y canal de la red conectada y cuántas redes más comparten ese
# canal, de system_profiler (airport ya no existe en macOS 14.4+). Solo revisa: termina con 10.
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
tarjeta() { networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: (Wi-Fi|AirPort)/ {w = 1; next} /^Device:/ {if (w) {print $2; exit}}'; }

case ${1:-} in
diagnosticar)
  [ -n "$(tarjeta)" ] || { echo "No encontré una tarjeta Wi-Fi en este equipo."; exit 10; }
  datos=$(con_limite 20 system_profiler SPAirPortDataType 2>/dev/null)
  # «canal|banda|dBm|redes en el mismo canal» de la red conectada
  r=$(printf '%s\n' "$datos" | awk '
    /Current Network Information:/ {a = 1; o = 0; next}
    /Other Local Wi-Fi Networks:/ {a = 0; o = 1; next}
    a && /Channel:/ && c == "" {c = $2; b = $3; gsub(/[(,]/, "", b)}
    a && /Signal \/ Noise:/ && s == "" {s = $4}
    o && /Channel:/ {n[$2]++}
    END {if (c != "") printf "%s|%s|%s|%d\n", c, b, s, n[c]}')
  [ -n "$r" ] || { echo "El Wi-Fi no está conectado a ninguna red: para eso usa «Reconectar el Wi-Fi»."; exit 10; }
  IFS='|' read -r canal banda dbm otras <<< "$r"
  case ${dbm:-} in -[0-9]*) ;; *) dbm= ;; esac
  if [ -z "$dbm" ]; then echo "El Wi-Fi está conectado, pero no pude leer la intensidad de la señal."
  elif [ "$dbm" -ge -60 ]; then echo "La señal del Wi-Fi es buena ($dbm dBm)."
  elif [ "$dbm" -ge -70 ]; then echo "La señal del Wi-Fi es regular ($dbm dBm): acercarte al router o quitar obstáculos (paredes, muebles metálicos) ayudaría."
  else echo "La señal del Wi-Fi es débil ($dbm dBm): por eso puede ir lento o cortarse. Acércate al router o, si puedes, usa un cable."; fi
  case $banda in
  6GHz) echo "Estás en la banda de 6 GHz (canal $canal): es la más rápida, pero la de menos alcance." ;;
  5GHz) echo "Estás en la banda de 5 GHz (canal $canal): es rápida, pero atraviesa peor las paredes que la de 2,4 GHz." ;;
  2GHz) echo "Estás en la banda de 2,4 GHz (canal $canal): llega más lejos, pero es más lenta y suele estar saturada. Si el router tiene una red de 5 GHz, úsala cuando estés cerca." ;;
  esac
  if [ "${otras:-0}" -ge 4 ]; then echo "Hay $otras redes más en el mismo canal: está saturado. Quien administra el router puede cambiarlo de canal."; fi
  echo "La señal va de -30 dBm (excelente) a -90 dBm (casi sin señal)."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
