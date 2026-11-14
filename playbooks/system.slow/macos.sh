#!/bin/bash
# Revisar por qué el Mac está lento: carga del procesador, memoria (el porcentaje libre que calcula macOS, el mismo de
# memory_pressure), intercambio, disco de datos y días sin reiniciar. Solo lectura: termina con 10. Bash 3.2.
set -u
case ${1:-} in
diagnosticar)
  nucleos=$(sysctl -n hw.ncpu 2>/dev/null); nucleos=${nucleos:-1}
  carga=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')  # «{ 1.23 1.45 1.50 }»
  carga=${carga:-0}
  libre=$(sysctl -n kern.memorystatus_level 2>/dev/null)
  [ -n "$libre" ] || libre=$(memory_pressure -Q 2>/dev/null | sed -n 's/.*percentage: *\([0-9]*\)%.*/\1/p')
  libre=${libre:-100}
  usada=$((100 - libre))
  total=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1 / 1073741824}')
  # «total = 2048.00M  used = 1024.50M  free = 1023.50M  (encrypted)»
  swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '{t = $3 + 0; u = $6 + 0; print (t > 0 ? int(100 * u / t) : 0)}')
  swap=${swap:-0}
  vol=/System/Volumes/Data; [ -d "$vol" ] || vol=/
  disco=$(df -k "$vol" 2>/dev/null | awk 'NR == 2 {print $5 + 0}'); disco=${disco:-0}
  arranque=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')
  dias=$(( ($(date +%s) - ${arranque:-$(date +%s)}) / 86400 ))
  echo "Procesador: carga $carga con $nucleos núcleos. Memoria: $usada % usada de ${total:-?} GB. Disco de datos: $disco % lleno. Sin reiniciar: $dias día(s)."
  echo "Lo que más consume ahora:"
  # sumado por programa (un navegador son muchos procesos «… Helper»); los nombres pueden llevar espacios
  ps -Aco pcpu=,pmem=,comm= 2>/dev/null | awk '{c = $1; m = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); sub(/ Helper( \(.*\))?$/, "")}
    $0 != "ps" && $0 != "" {pc[$0] += c; pm[$0] += m} END {for (k in pc) if (pc[k] > 5 || pm[k] > 5) printf "%.0f\t%s\t%.1f\n", pc[k], k, pm[k]}' |
    sort -rn | head -5 | awk -F'\t' '{printf "- %s: %s %% de procesador, %s %% de memoria\n", $2, $1, $3}'
  consejos=""
  awk -v c="$carga" -v n="$nucleos" 'BEGIN {exit !(c > n)}' && consejos="${consejos}El procesador está al límite: cierra los programas que más consumen.
"
  { [ "$usada" -ge 85 ] || [ "$swap" -ge 50 ]; } && consejos="${consejos}La memoria está casi llena: cierra pestañas del navegador y programas que no uses.
"
  [ "$disco" -ge 90 ] && consejos="${consejos}El disco está casi lleno: pídeme liberar espacio en disco.
"
  [ "$dias" -ge 7 ] && consejos="${consejos}Lleva $dias días sin reiniciarse: guarda tu trabajo y reinícialo.
"
  if [ -z "$consejos" ]; then echo "No veo nada fuera de lo normal en este momento."
  else printf '%s' "$consejos"; fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
