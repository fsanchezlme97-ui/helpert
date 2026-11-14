#!/bin/bash
# Equivalente en macOS del punto de restauración: una instantánea local de Time Machine del volumen de datos
# (tmutil localsnapshot). Desde la Recuperación de macOS («Restaurar desde Time Machine») se puede volver a ella.
# macOS las borra solas a las 24 horas, o antes si falta espacio: se dice. No configura Time Machine. Bash 3.2.
set -u
vol=/System/Volumes/Data; [ -d "$vol" ] || vol=/
# fechas (AAAA-MM-DD-HHMMSS, hora local) de las instantáneas locales, la más reciente al final
fechas() { tmutil listlocalsnapshots "$vol" 2>/dev/null | sed -n 's/^com\.apple\.TimeMachine\.\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]-[0-9]\{6\}\)\.local$/\1/p' | sort; }
legible() { date -j -f '%Y-%m-%d-%H%M%S' "$1" '+%d/%m/%Y %H:%M' 2>/dev/null; }
# minutos desde la más reciente, o nada si no hay. El nombre debería llevar la hora local; por si lleva la UTC, se
# toma la lectura más cercana a ahora que no quede en el futuro
edad() {
  local u a b m=99999 x; u=$(fechas | tail -1); [ -n "$u" ] || return 0
  a=$(date -j -f '%Y-%m-%d-%H%M%S' "$u" +%s 2>/dev/null); b=$(TZ=UTC0 date -j -f '%Y-%m-%d-%H%M%S' "$u" +%s 2>/dev/null)
  for x in $a $b; do
    x=$(( ($(date +%s) - x) / 60 )); [ "$x" -lt 0 ] && [ "$x" -ge -2 ] && x=0
    [ "$x" -ge 0 ] && [ "$x" -lt "$m" ] && m=$x
  done
  echo "$m"
}
nosepuede() {
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para guardar una instantánea del sistema."; return 0; }
  command -v tmutil >/dev/null || { echo "Este Mac no tiene la herramienta de Time Machine (tmutil)."; return 0; }
  return 1
}

case ${1:-} in
diagnosticar)
  nosepuede && exit 3
  e=$(edad)
  if [ -n "$e" ] && [ "$e" -lt 60 ]; then
    echo "Ya hay una instantánea local de Time Machine de hace $e minuto(s) ($(legible "$(fechas | tail -1)"))."
    echo "Sirve para volver atrás durante unas 24 horas; macOS la borra después, o antes si falta espacio."
    exit 10
  fi
  if [ -n "$e" ]; then echo "La última instantánea local de Time Machine es del $(legible "$(fechas | tail -1)")."
  else echo "Este Mac no tiene ninguna instantánea local de Time Machine."; fi
  echo "Guardaría una nueva ahora: tarda unos segundos y no cambia nada de tus archivos ni programas."
  echo "macOS la guarda unas 24 horas (menos si falta espacio): sirve para un cambio que se hace hoy."
  exit 0 ;;
comprobar)
  nosepuede && exit 3
  exit 0 ;;
aplicar)
  nosepuede && exit 1
  antes=$(fechas)
  r=$(tmutil localsnapshot 2>&1)
  [ "$(fechas | tail -1)" != "$(printf '%s\n' "$antes" | tail -1)" ] || { echo "macOS no pudo guardar la instantánea ($(printf '%s' "$r" | tail -1)). Avisa a soporte."; exit 1; }
  echo "Guardé una instantánea local de Time Machine. Si algo sale mal en las próximas 24 horas, soporte puede devolver el equipo a este momento desde la Recuperación de macOS."
  exit 0 ;;
verificar)
  e=$(edad)
  { [ -n "$e" ] && [ "$e" -lt 15 ]; } || { echo "No encuentro una instantánea local reciente."; exit 1; }
  echo "Hay una instantánea local del $(legible "$(fechas | tail -1)")."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
