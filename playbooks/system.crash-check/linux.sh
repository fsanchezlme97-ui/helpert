#!/bin/bash
# Ver por qué el equipo se apagó solo: revisa en el registro del sistema (journal) cómo terminaron los últimos
# arranques. Uno que no termina con el apagado normal se cortó: se busca la causa en sus últimas líneas
# (error grave del núcleo, temperatura, batería, botón de encendido). Solo lectura: termina con 10.
set -u
NORMAL='System is (rebooting|powering down)|Journal stopped|systemd-shutdown|Reached target .*(Shutdown|Power-Off|Reboot|Final Step)'

causa() {  # $1: líneas finales de un arranque
  if grep -Eqi 'kernel panic|Oops:|BUG: |general protection fault|watchdog: .*(hard|soft) LOCKUP' <<< "$1"; then
    echo "error grave del sistema (el núcleo se detuvo)"
  elif grep -Eqi 'critical temperature|thermal.*(shutdown|critical)|temperature above threshold' <<< "$1"; then
    echo "se calentó demasiado y se apagó para protegerse"
  elif grep -Eqi 'battery.*(critical|low)|critical battery' <<< "$1"; then
    echo "se quedó sin batería"
  elif grep -Eqi 'Power key pressed long|power button.*long' <<< "$1"; then
    echo "se mantuvo apretado el botón de encendido"
  elif grep -Eqi 'Out of memory: Killed' <<< "$1"; then
    echo "se quedó sin memoria y dejó de responder"
  else
    echo "se cortó de golpe (corte de luz, batería agotada o equipo congelado)"
  fi
}

case ${1:-} in
diagnosticar)
  command -v journalctl >/dev/null || { echo "Este sistema no tiene el registro de systemd (journal); no puedo revisarlo."; exit 1; }
  n=$(journalctl --list-boots -q --no-pager 2>/dev/null | grep -c .)
  if [ "$n" -le 1 ]; then
    echo "El sistema no guarda el registro de los arranques anteriores, así que no puedo saber por qué se apagó."
    echo "Si vuelve a pasar, avisa a soporte para que active el registro permanente."
    exit 1
  fi
  [ "$n" -gt 6 ] && n=6
  malos=0; hallazgos=; temp=0; panico=0
  for i in $(seq 1 $((n - 1))); do
    fin=$(journalctl -b "-$i" -n 300 -o cat --no-pager 2>/dev/null)
    [ -n "$fin" ] || continue
    tail -n 40 <<< "$fin" | grep -Eq "$NORMAL" && continue
    malos=$((malos + 1))
    cuando=$(journalctl -b "-$i" -n 1 -o short-iso --no-pager 2>/dev/null | tail -1 | cut -c1-16 | tr T ' ')
    c=$(causa "$fin")
    case $c in *calentó*) temp=1 ;; *núcleo*) panico=1 ;; esac
    hallazgos="$hallazgos- $cuando: $c."$'\n'
  done
  # systemd-pstore guarda aquí lo que el núcleo alcanzó a escribir antes de un error grave
  [ -n "$(find /var/lib/systemd/pstore -mindepth 1 -mtime -30 2>/dev/null | head -1)" ] && panico=1 &&
    hallazgos="$hallazgos- Además, el sistema guardó el informe de un error grave del núcleo en los últimos 30 días."$'\n'
  if [ "$malos" -eq 0 ] && [ "$panico" -eq 0 ]; then
    echo "En los últimos $((n - 1)) arranques el equipo siempre se apagó o reinició de forma normal."
    exit 10
  fi
  echo "En los últimos $((n - 1)) arranques encontré $malos apagado(s) inesperado(s):"
  printf '%s' "$hallazgos"
  [ "$temp" -eq 1 ] && echo "El calor apaga el equipo: pide a un técnico que limpie los ventiladores."
  [ "$panico" -eq 1 ] && echo "Un error grave del sistema puede venir de un controlador o del hardware: avisa a soporte con esta información."
  [ "$temp" -eq 0 ] && [ "$panico" -eq 0 ] && echo "Si vuelve a pasar con el cargador conectado, avisa a soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
