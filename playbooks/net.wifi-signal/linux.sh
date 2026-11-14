#!/bin/bash
# Revisar la señal del Wi-Fi (NetworkManager): intensidad (%), banda y canal de la red conectada y cuántas redes más
# comparten ese canal. Usa la última búsqueda de redes, sin volver a buscar. Solo revisa: termina con 10.
set -u
tarjeta() { nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}'; }
# IN-USE:SIGNAL:CHAN:FREQ:SSID (el SSID al final, porque nmcli escapa sus «:» con «\:»)
redes() { nmcli -t -f IN-USE,SIGNAL,CHAN,FREQ,SSID device wifi list ifname "$1" --rescan no 2>/dev/null; }

case ${1:-} in
diagnosticar)
  command -v nmcli >/dev/null || { echo "Este equipo no usa NetworkManager: no sé leer la señal del Wi-Fi."; exit 1; }
  d=$(tarjeta)
  [ -n "$d" ] || { echo "No encontré una tarjeta Wi-Fi en este equipo."; exit 10; }
  lista=$(redes "$d")
  actual=$(printf '%s\n' "$lista" | grep '^\*' | head -1)
  [ -n "$actual" ] || { echo "El Wi-Fi no está conectado a ninguna red: para eso usa «Reconectar el Wi-Fi»."; exit 10; }
  IFS=: read -r _ senal canal frec ssid <<< "$actual"
  ssid=${ssid//\\:/:}; frec=${frec%% *}
  case ${senal:-} in ''|*[!0-9]*) senal=0 ;; esac
  case ${frec:-} in ''|*[!0-9]*) frec=0 ;; esac
  otras=$(printf '%s\n' "$lista" | awk -F: -v c="$canal" '$1 != "*" && $3 == c' | wc -l | tr -d ' ')

  if [ "$senal" -ge 70 ]; then echo "La señal del Wi-Fi es buena ($senal %) en la red «$ssid»."
  elif [ "$senal" -ge 40 ]; then echo "La señal del Wi-Fi es regular ($senal %) en la red «$ssid»: acercarte al router o quitar obstáculos (paredes, muebles metálicos) ayudaría."
  else echo "La señal del Wi-Fi es débil ($senal %) en la red «$ssid»: por eso puede ir lento o cortarse. Acércate al router o, si puedes, usa un cable."; fi
  if [ "$frec" -ge 5925 ]; then echo "Estás en la banda de 6 GHz (canal $canal): es la más rápida, pero la de menos alcance."
  elif [ "$frec" -ge 4900 ]; then echo "Estás en la banda de 5 GHz (canal $canal): es rápida, pero atraviesa peor las paredes que la de 2,4 GHz."
  elif [ "$frec" -gt 0 ]; then echo "Estás en la banda de 2,4 GHz (canal $canal): llega más lejos, pero es más lenta y suele estar saturada. Si el router tiene una red de 5 GHz, úsala cuando estés cerca."; fi
  if [ "${otras:-0}" -ge 4 ]; then echo "Hay $otras redes más en el mismo canal: está saturado. Quien administra el router puede cambiarlo de canal."; fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
