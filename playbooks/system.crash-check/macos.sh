#!/bin/bash
# Ver por qué el Mac se apagó solo: al arrancar, macOS anota la causa del apagado anterior («Previous shutdown cause»)
# en el registro unificado; se leen los últimos 7 días (con tope de 90 s) y los informes de error grave del núcleo
# (panic) de los últimos 30 días. Solo lectura: termina con 10.
set -u
causa() {  # códigos conocidos del SMC; 5 es el apagado normal
  case $1 in
  3) echo "se mantuvo apretado el botón de encendido" ;;
  0) echo "se cortó la corriente" ;;
  -60|-103) echo "se quedó sin batería" ;;
  -3|-74|-75|-86|-95|-100|-104) echo "se calentó demasiado y se apagó para protegerse" ;;
  -62) echo "se congeló y el sistema lo reinició" ;;
  *) echo "error del hardware o del sistema (código $1)" ;;
  esac
}

case ${1:-} in
diagnosticar)
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  # macOS no trae timeout: se corta a mano si tarda demasiado
  log show --last 7d --style compact --predicate 'eventMessage CONTAINS "Previous shutdown cause"' >"$tmp" 2>/dev/null &
  p=$!
  for _ in $(seq 1 90); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  corto=0; kill -0 "$p" 2>/dev/null && { corto=1; kill "$p" 2>/dev/null; }; wait "$p" 2>/dev/null
  # «2026-11-10 09:01:22.123 Df kernel[0:12a] (AppleSMC) Previous shutdown cause: -128»
  malos=$(awk '/Previous shutdown cause:/ && $NF != 5 && $NF ~ /^-?[0-9]+$/ {print $1 " " substr($2, 1, 5) " " $NF}' "$tmp")
  panicos=$(find /Library/Logs/DiagnosticReports -maxdepth 2 -type f \( -name '*.panic' -o -name 'panic-*' -o -name 'Kernel*' \) -mtime -30 2>/dev/null | grep -c .)
  temp=0
  if [ -z "$malos" ] && [ "$panicos" -eq 0 ]; then
    if [ "$corto" -eq 1 ]; then echo "No encontré apagados inesperados, pero el registro tardó demasiado y no pude revisarlo entero."
    else echo "En los últimos 7 días el equipo no tuvo apagados inesperados ni errores graves del sistema."; fi
    exit 10
  fi
  if [ -n "$malos" ]; then
    echo "En los últimos 7 días encontré $(printf '%s\n' "$malos" | grep -c .) apagado(s) inesperado(s):"
    while read -r dia hora codigo; do
      c=$(causa "$codigo"); case $c in *calentó*) temp=1 ;; esac
      echo "- $dia $hora: $c."
    done <<EOF
$(printf '%s\n' "$malos" | tail -5)
EOF
  fi
  [ "$panicos" -gt 0 ] && echo "El sistema guardó $panicos informe(s) de error grave (pánico del núcleo) en los últimos 30 días."
  if [ "$temp" -eq 1 ]; then echo "El calor apaga el equipo: pide a un técnico que limpie los ventiladores."
  elif [ "$panicos" -gt 0 ]; then echo "Un error grave del sistema puede venir de un programa de bajo nivel o del hardware: avisa a soporte con esta información."
  else echo "Si vuelve a pasar con el cargador conectado, avisa a soporte."; fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
