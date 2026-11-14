#!/bin/bash
# Revisar la suspensión en macOS: qué programa la impide ahora (pmset), si la suspensión automática está apagada y qué
# despertó al equipo la última vez. Solo lectura: termina con 10. Compatible con bash 3.2.
set -u
# «due to X» del registro de pmset en palabras
motivo() {
  case $1 in
    *Lid*|*lid*) echo "abrir la tapa" ;; *PowerButton*|*PWRB*) echo "el botón de encendido" ;;
    *RTC*|*Maintenance*|*SleepService*) echo "una tarea programada de macOS (mantenimiento o Power Nap)" ;;
    *ARPT*|*WiFi*|*wifi*|*EN0*|*en0*|*Network*) echo "la red (Wi-Fi o cable)" ;;
    *XHC*|*USB*|*HID*|*UserActivity*) echo "el teclado, el mouse u otro dispositivo USB" ;;
    *) echo "$1" ;;
  esac
}

case ${1:-} in
diagnosticar)
  command -v pmset >/dev/null || { echo "No puedo revisar la suspensión en este equipo."; exit 1; }
  ajustes=$(pmset -g 2>/dev/null)
  avisos=""
  # programas que impiden la suspensión (powerd es macOS mismo mientras la pantalla está encendida)
  bloquean=$(pmset -g assertions 2>/dev/null | sed -n 's/^ *pid [0-9]*(\([^)]*\)):.*Prevent\(UserIdle\)\{0,1\}SystemSleep.*/\1/p' |
             grep -v '^powerd$' | sort -u | head -5 | paste -sd, - | sed 's/,/, /g')
  [ -n "$bloquean" ] && avisos="${avisos}- Ahora impide la suspensión: $bloquean. Ciérralo o termina lo que esté haciendo (una descarga, una llamada, un video).
"
  minutos=$(echo "$ajustes" | awk '$1 == "sleep" {print $2; exit}')
  [ "${minutos:-}" = 0 ] && avisos="${avisos}- La suspensión automática está apagada: el equipo nunca se suspende solo. Puedes activarla en Configuración del Sistema > Batería o Ahorro de energía.
"
  if [ -z "$avisos" ]; then echo "La suspensión está activa y ningún programa la está impidiendo ahora."
  else echo "Encontré lo que puede estar fallando con la suspensión:"; printf '%s' "$avisos"; fi
  # qué lo despertó la última vez
  ultimo=$(pmset -g log 2>/dev/null | grep -E '[[:space:]](Wake|DarkWake)[[:space:]]' | grep 'due to' | tail -1)
  if [ -n "$ultimo" ]; then
    cuando=$(echo "$ultimo" | awk '{split($1, d, "-"); print d[3] "/" d[2] "/" d[1], "a las", substr($2, 1, 5)}')
    por=$(echo "$ultimo" | sed -n 's/.*due to \([^ /:]*\).*/\1/p')
    echo "La última vez se despertó el $cuando por $(motivo "${por:-desconocido}")."
  fi
  echo "$ajustes" | awk '$1 == "womp" && $2 == 1 {f = 1} END {exit !f}' && echo "Está activado «despertar para acceso a la red»: otros equipos pueden despertarlo. Si no lo necesitas, apágalo en Configuración del Sistema."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
