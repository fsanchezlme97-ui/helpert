#!/bin/bash
# Revisar la batería del Mac: carga y cargador (pmset), ciclos y salud (ioreg) y el estado que da macOS
# (system_profiler: «Normal» o «Service Recommended»). Solo lectura: termina con 10.
set -u
io() { ioreg -rn AppleSmartBattery 2>/dev/null | awk -v k="\"$1\"" '$1 == k {print $3; exit}'; }

case ${1:-} in
diagnosticar)
  batt=$(pmset -g batt 2>/dev/null)
  echo "$batt" | grep -q InternalBattery || { echo "Este equipo no tiene batería (o macOS no la detecta)."; exit 10; }
  carga=$(echo "$batt" | grep InternalBattery | grep -o '[0-9]*%' | head -1 | tr -d %)
  echo "$batt" | grep -q "'AC Power'" && cargador=conectado || cargador=desconectado
  estado=$(echo "$batt" | grep InternalBattery | awk -F'; ' '{print $2}')
  case $estado in charging) e=", cargando" ;; charged) e=", llena" ;; discharging) e=", descargándose" ;; *) e="" ;; esac
  ciclos=$(io CycleCount)
  # en Apple Silicon MaxCapacity es un %; la capacidad real en mAh es AppleRawMaxCapacity
  maxima=$(io AppleRawMaxCapacity); [ -n "$maxima" ] || maxima=$(io MaxCapacity)
  fabrica=$(io DesignCapacity)
  salud=
  if [ -n "$maxima" ] && [ "${fabrica:-0}" -gt 0 ] 2>/dev/null; then salud=$((100 * maxima / fabrica)); [ "$salud" -gt 100 ] && salud=100; fi
  condicion=$(system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Condition:/ {print $2; exit}')
  echo "Batería al ${carga:-?} %$e. Cargador: $cargador."
  [ -n "$salud" ] && echo "Salud: $salud % de la capacidad que tenía nueva."
  [ -n "$ciclos" ] && echo "Ciclos de carga: $ciclos."
  case $condicion in
  *Service*|*Replace*|*Check*) echo "macOS recomienda revisar la batería: pide a soporte que la cambien." ;;
  *) if [ -n "$salud" ] && [ "$salud" -lt 80 ]; then echo "La batería ya está gastada y dura menos que nueva; si no te alcanza, pide a soporte que la cambien."; fi ;;
  esac
  [ "$cargador" = conectado ] && [ "$estado" = discharging ] && echo "El cargador está conectado pero la batería se descarga: prueba otro enchufe o cargador; si sigue igual, avisa a soporte."
  [ "$cargador" = conectado ] && echo "$batt" | grep -q 'not charging' &&
    echo "No está cargando aunque el cargador está conectado. macOS puede frenar la carga para cuidar la batería (carga optimizada); si no es eso, prueba otro cargador."
  [ "$cargador" = desconectado ] && [ "${carga:-100}" -le 15 ] 2>/dev/null && echo "Queda poca carga: conecta el cargador."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
