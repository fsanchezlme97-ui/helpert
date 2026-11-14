#!/bin/bash
# Revisar la temperatura: la del procesador (sensores hwmon del núcleo: coretemp, k10temp…; si no, las zonas
# térmicas), los ventiladores si se ven, las veces que el procesador frenó por calor y los programas que más
# procesador usan. Sin herramientas extra (lm-sensors no hace falta). Solo lectura: termina con 10.
set -u
leer() { tr -d '\n' 2>/dev/null < "$1"; }
maximo() { sort -n | tail -1; }
# «pid tics nombre» de cada proceso: tiempo de procesador gastado (utime + stime, campos 14 y 15 de /proc/<pid>/stat)
muestra() {
  cat /proc/[0-9]*/stat 2>/dev/null | awk '{
    match($0, /\(.*\)/); n = substr($0, RSTART + 1, RLENGTH - 2); split(substr($0, RSTART + RLENGTH + 1), f, " ")
    gsub(/[ \t]/, "_", n); print $1, f[12] + f[13], n}'
}

case ${1:-} in
diagnosticar)
  t=
  for h in /sys/class/hwmon/hwmon*; do
    case $(leer "$h/name") in coretemp|k10temp|zenpower|cpu_thermal|soc_thermal|acpitz)
      v=$(cat "$h"/temp*_input 2>/dev/null | maximo); [ -n "$v" ] && t=$(printf '%s\n%s\n' "$t" "$v" | grep . | maximo) ;;
    esac
  done
  [ -n "$t" ] || t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | maximo)
  ventilador=$(cat /sys/class/hwmon/hwmon*/fan*_input 2>/dev/null | maximo)
  frenos=$(cat /sys/devices/system/cpu/cpu*/thermal_throttle/package_throttle_count 2>/dev/null | maximo)
  if [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null; then
    c=$((t / 1000))
    if [ "$c" -ge 90 ]; then echo "El procesador está muy caliente: $c °C."
    elif [ "$c" -ge 80 ]; then echo "El procesador está caliente: $c °C."
    else echo "La temperatura del procesador es normal: $c °C."; fi
  else
    c=0; echo "No pude leer la temperatura: este equipo no muestra sus sensores al sistema."
  fi
  [ "${ventilador:-0}" -gt 0 ] 2>/dev/null && echo "El ventilador gira a $ventilador RPM."
  [ "${frenos:-0}" -gt 0 ] 2>/dev/null && echo "Desde que se encendió, el procesador tuvo que frenar $frenos vez(es) para no calentarse más."
  # uso de cada programa en 2 segundos, sumado por programa (un navegador son muchos procesos), en % del procesador entero
  antes=$(muestra); sleep 2; despues=$(muestra)
  total=$(( $(getconf CLK_TCK) * 2 * $(nproc) ))
  top=$(awk -v t="$total" 'NR == FNR {a[$1] = $2; next} ($1 in a) && $2 > a[$1] {c[$3] += $2 - a[$1]}
          END {for (k in c) if (100 * c[k] / t >= 1) printf "%.0f\t%s\n", 100 * c[k] / t, k}' <(echo "$antes") <(echo "$despues") |
        sort -rn | head -3 | awk -F'\t' '{printf "- %s: %s %%\n", $2, $1}')
  if [ -n "$top" ]; then echo "Lo que más procesador usa ahora:"; echo "$top"
  else echo "Ningún programa está usando mucho el procesador ahora."; fi
  if [ "$c" -ge 80 ] || [ "${frenos:-0}" -gt 0 ] 2>/dev/null; then
    echo "Úsalo sobre una mesa (no sobre la cama o las piernas) y cierra lo que no uses. Si se calienta seguido, pide a un técnico que lo limpie."
  fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
