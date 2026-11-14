#!/bin/bash
# Revisar la batería: carga, salud (capacidad actual frente a la de fábrica), ciclos y cargador, desde
# /sys/class/power_supply. Solo lectura: termina con 10.
set -u
leer() { tr -d '\n' 2>/dev/null < "$1"; }

case ${1:-} in
diagnosticar)
  bat=
  for b in /sys/class/power_supply/*; do [ "$(leer "$b/type")" = Battery ] && [ "$(leer "$b/scope")" != Device ] && { bat=$b; break; }; done
  [ -n "$bat" ] || { echo "Este equipo no tiene batería (o el sistema no la detecta)."; exit 10; }
  carga=$(leer "$bat/capacity"); estado=$(leer "$bat/status"); ciclos=$(leer "$bat/cycle_count")
  lleno=$(leer "$bat/energy_full"); fabrica=$(leer "$bat/energy_full_design")
  [ -n "$lleno" ] || { lleno=$(leer "$bat/charge_full"); fabrica=$(leer "$bat/charge_full_design"); }
  salud=; [ -n "$lleno" ] && [ "${fabrica:-0}" -gt 0 ] 2>/dev/null && salud=$((100 * lleno / fabrica))
  [ -n "$salud" ] && [ "$salud" -gt 100 ] && salud=100
  cargador=no
  for a in /sys/class/power_supply/*; do
    case $(leer "$a/type") in Mains|USB|USB_C|USB_PD) [ "$(leer "$a/online")" = 1 ] && cargador=si ;; esac
  done
  case $estado in Charging) e="cargando" ;; Discharging) e="descargándose" ;; Full) e="llena" ;; "Not charging") e="sin cargar" ;; *) e="" ;; esac
  echo "Batería al ${carga:-?} %${e:+, $e}. Cargador: $([ "$cargador" = si ] && echo conectado || echo desconectado)."
  [ -n "$salud" ] && echo "Salud: $salud % de la capacidad que tenía nueva."
  [ "${ciclos:-0}" -gt 0 ] 2>/dev/null && echo "Ciclos de carga: $ciclos."
  if [ -n "$salud" ] && [ "$salud" -lt 60 ]; then echo "La batería está muy gastada: pide a soporte que la cambien."
  elif [ -n "$salud" ] && [ "$salud" -lt 80 ]; then echo "La batería ya está gastada y dura menos que nueva; si no te alcanza, pide a soporte que la cambien."; fi
  [ "$cargador" = si ] && [ "$estado" = Discharging ] && echo "El cargador está conectado pero la batería se descarga: prueba otro enchufe o cargador; si sigue igual, avisa a soporte."
  [ "$cargador" = no ] && [ "${carga:-100}" -le 15 ] 2>/dev/null && echo "Queda poca carga: conecta el cargador."
  [ "$cargador" = si ] && [ "$estado" = "Not charging" ] && [ "${carga:-100}" -lt 95 ] 2>/dev/null &&
    echo "No está cargando aunque el cargador está conectado. Algunos equipos frenan la carga para cuidar la batería; si no es así, prueba otro cargador o avisa a soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
