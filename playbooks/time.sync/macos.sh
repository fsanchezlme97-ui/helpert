#!/bin/bash
# Corregir la hora (macOS): activa «Ajustar fecha y hora automáticamente» (systemsetup) y la sincroniza ya con el servidor
# configurado (sntp -sS, lo que indica Apple; si no basta, se reinicia timed, el servicio de hora). Para saber si quedó
# bien se mide el desfase con sntp, sin fijar nada. No cambia la zona horaria.
set -u
TOLERANCIA=5  # segundos
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
activa() { systemsetup -getusingnetworktime 2>/dev/null | grep -qi ': on'; }
servidor() {
  s=$(systemsetup -getnetworktimeserver 2>/dev/null | awk -F': ' '/Server/ {print $2; exit}' | awk '{print $1}')
  echo "${s:-time.apple.com}"
}
# segundos que el reloj va adelantado (+) o atrasado (-) según el servidor; vacío si no responde.
# sntp da «+0.012345 +/- 0.03 time.apple.com 17.253.x.x»: el desfase es el número con signo (es lo que el servidor
# le suma al reloj, así que se le cambia el signo)
desfase() { tope 8 sntp "$srv" 2>/dev/null | awk '/\+\/-/ {for (i = 1; i <= NF; i++) if ($i ~ /^[+-][0-9]+(\.[0-9]+)?$/) {printf "%.0f\n", -$i; exit}}'; }
bien() { [ -n "$1" ] && [ "${1#-}" -le "$TOLERANCIA" ]; }
ahora() { date '+%d/%m/%Y %H:%M'; }

case ${1:-} in
diagnosticar)
  { command -v systemsetup >/dev/null && command -v sntp >/dev/null; } || { echo "No puedo revisar la hora en este equipo."; exit 1; }
  srv=$(servidor)
  d=$(desfase)
  if activa && bien "$d"; then echo "La hora del equipo está sincronizada por internet: $(ahora)."; exit 10; fi
  activa || echo "La hora automática está desactivada."
  if [ -z "$d" ]; then echo "No pude comparar la hora con el servidor de hora; puede que la red lo bloquee (ahora marca $(ahora))."
  elif ! bien "$d"; then
    if [ "$d" -gt 0 ]; then echo "La hora del equipo va ${d#-} segundos adelantada (ahora marca $(ahora))."
    else echo "La hora del equipo va ${d#-} segundos atrasada (ahora marca $(ahora))."; fi
  fi
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para ajustar la hora."; exit 3; }
  exit 0 ;;
aplicar)
  activa || systemsetup -setusingnetworktime on >/dev/null 2>&1
  activa || { echo "No se pudo activar la hora automática."; exit 1; }
  srv=$(servidor)
  tope 15 sntp -sS "$srv" >/dev/null 2>&1
  d=$(desfase)
  if [ -n "$d" ] && ! bien "$d"; then
    killall timed 2>/dev/null  # launchd lo vuelve a abrir y sincroniza al arrancar
    fin=$((SECONDS + 16)); while [ "$SECONDS" -lt "$fin" ]; do sleep 4; d=$(desfase); [ -z "$d" ] || bien "$d" && break; done
  fi
  echo "Activé la hora automática y pedí sincronizarla."
  exit 0 ;;
verificar)
  srv=$(servidor); d=$(desfase)
  { activa && bien "$d"; } || { echo "La hora todavía no se sincroniza; puede que la red bloquee el servicio de hora."; exit 1; }
  echo "La hora está sincronizada: $(ahora)."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
