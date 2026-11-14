#!/bin/bash
# Revisar por qué el equipo está lento. Solo lectura: el diagnóstico informa y termina con 10.
set -u
case ${1:-} in
diagnosticar)
  nucleos=$(nproc)
  carga=$(cut -d' ' -f1 /proc/loadavg)
  read -r total disponible <<< "$(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {print int(t/1024), int(a/1024)}' /proc/meminfo)"
  swap=$(awk '/^SwapTotal/ {t=$2} /^SwapFree/ {f=$2} END {print (t ? int(100*(t-f)/t) : 0)}' /proc/meminfo)
  disco=$(df --output=pcent / | tail -1 | tr -dc 0-9)
  dias=$(awk '{print int($1/86400)}' /proc/uptime)
  usada=$(( 100 * (total - disponible) / total ))
  echo "Procesador: carga $carga con $nucleos núcleos. Memoria: $usada % usada de $((total / 1024)) GB. Disco del sistema: $disco % lleno. Sin reiniciar: $dias día(s)."
  echo "Lo que más consume ahora:"
  # sumado por programa (un navegador son muchos procesos); sin contar esta misma revisión
  ps -eo pcpu=,pmem=,comm= | awk '$3 != "ps" {c[$3] += $1; m[$3] += $2} END {for (k in c) if (c[k] > 5 || m[k] > 5) printf "%.0f\t%s\t%.1f\n", c[k], k, m[k]}' |
    sort -rn | head -5 | awk -F'\t' '{printf "- %s: %s %% de procesador, %s %% de memoria\n", $2, $1, $3}'
  consejos=()
  awk -v c="$carga" -v n="$nucleos" 'BEGIN {exit !(c > n)}' && consejos+=("El procesador está al límite: cierra los programas que más consumen.")
  [ "$usada" -ge 85 ] || [ "$swap" -ge 50 ] && consejos+=("La memoria está casi llena: cierra pestañas del navegador y programas que no uses.")
  [ "$disco" -ge 90 ] && consejos+=("El disco está casi lleno: pídeme liberar espacio en disco.")
  [ "$dias" -ge 7 ] && consejos+=("Lleva $dias días sin reiniciarse: guarda tu trabajo y reinícialo.")
  if [ ${#consejos[@]} -eq 0 ]; then echo "No veo nada fuera de lo normal en este momento."
  else printf '%s\n' "${consejos[@]}"; fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
