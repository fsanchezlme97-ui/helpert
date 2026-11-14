#!/bin/bash
# Revisar la temperatura del Mac: powermetrics (como root) da la presión térmica (todos los Mac) y la temperatura del
# procesador (solo los Mac con Intel); pmset dice si macOS limita la velocidad por calor. También los programas que
# más procesador usan. Solo lectura: termina con 10.
set -u
case ${1:-} in
diagnosticar)
  presion=; grados=
  if [ "$(id -u)" -eq 0 ] && command -v powermetrics >/dev/null; then
    presion=$(powermetrics --samplers thermal -i 1000 -n 1 2>/dev/null | awk -F': ' '/pressure level/ {print $2; exit}')
    grados=$(powermetrics --samplers smc -i 1000 -n 1 2>/dev/null | awk '/CPU die temperature/ {printf "%.0f", $4; exit}')
  fi
  limite=$(pmset -g therm 2>/dev/null | awk -F'= *' '/CPU_Speed_Limit/ {print $2 + 0; exit}')
  calor=0
  case $presion in
  Nominal) echo "La temperatura del equipo es normal${grados:+: $grados °C}." ;;
  Moderate|Fair) echo "El equipo está tibio${grados:+ ($grados °C)}: macOS empieza a cuidar la temperatura."; calor=1 ;;
  Heavy|Serious|Trapping|Critical|Sleeping) echo "El equipo está muy caliente${grados:+ ($grados °C)}: macOS lo está frenando para enfriarlo."; calor=1 ;;
  *) if [ -n "$grados" ]; then echo "El procesador está a $grados °C."; [ "$grados" -ge 85 ] 2>/dev/null && calor=1
     else echo "No pude leer la temperatura de este equipo."; fi ;;
  esac
  [ -n "$limite" ] && [ "$limite" -lt 100 ] 2>/dev/null && { echo "macOS limita el procesador al $limite % de su velocidad por calor."; calor=1; }
  # en macOS, %cpu de ps ya es el uso reciente; sumado por programa y en % del procesador entero
  nucleos=$(sysctl -n hw.ncpu 2>/dev/null); [ "${nucleos:-0}" -gt 0 ] 2>/dev/null || nucleos=1
  top=$(ps -Ac -o pcpu= -o comm= | awk -v n="$nucleos" '{p = $1; $1 = ""; sub(/^ /, ""); if ($0 != "ps") c[$0] += p}
        END {for (k in c) if (c[k] / n >= 1) printf "%.0f\t%s\n", c[k] / n, k}' | sort -rn | head -3 | awk -F'\t' '{printf "- %s: %s %%\n", $2, $1}')
  if [ -n "$top" ]; then echo "Lo que más procesador usa ahora:"; echo "$top"
  else echo "Ningún programa está usando mucho el procesador ahora."; fi
  [ "$calor" -eq 1 ] && echo "Úsalo sobre una mesa (no sobre la cama o las piernas) y cierra lo que no uses. Si se calienta seguido, pide a un técnico que lo limpie."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
