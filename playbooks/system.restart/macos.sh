#!/bin/bash
# Reiniciar el Mac: programa un reinicio en 2 minutos y avisa en la pantalla de la persona. shutdown queda esperando
# en segundo plano en su propia sesión (setsid), así que el script termina enseguida y el reinicio sigue en pie.
set -u
AVISO="El equipo se reiniciará en 2 minutos. Guarda tu trabajo y cierra los programas."
usuario=${HP_USUARIO:-}

programado() { pgrep -x shutdown >/dev/null 2>&1; }
avisar() {  # notificación en la sesión gráfica de la persona; sin sesión, nada
  [ -n "$usuario" ] && [ "$usuario" != root ] || return 1
  uid=$(id -u "$usuario" 2>/dev/null) || return 1
  [ "$(stat -f %Su /dev/console 2>/dev/null)" = "$usuario" ] || return 1
  launchctl asuser "$uid" sudo -n -u "$usuario" osascript \
    -e "display notification \"$AVISO\" with title \"Reinicio en 2 minutos\" sound name \"Funk\"" </dev/null >/dev/null 2>&1
}

case ${1:-} in
diagnosticar)
  programado && { echo "Ya hay un reinicio programado en este equipo."; exit 10; }
  arranque=$(sysctl -n kern.boottime 2>/dev/null | sed 's/^{ sec = \([0-9]*\).*/\1/')
  case $arranque in ''|*[!0-9]*) arranque=$(date +%s) ;; esac
  echo "El equipo lleva $(( ($(date +%s) - arranque) / 86400 )) día(s) sin reiniciarse."
  echo "Puedo programar un reinicio en 2 minutos, con un aviso en tu pantalla para que guardes tu trabajo."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el equipo."; exit 3; }
  exit 0 ;;
aplicar)
  # sin las salidas del agente: shutdown sigue vivo hasta el reinicio y el agente esperaría a que las cierre
  shutdown -r +2 "$AVISO" </dev/null >/dev/null 2>&1 || { echo "El sistema no aceptó programar el reinicio."; exit 1; }
  echo "Programé el reinicio para las $(date -v+2M +%H:%M), dentro de 2 minutos. Guarda tu trabajo y cierra los programas."
  avisar || echo "No pude mostrarte el aviso en la pantalla: guarda tu trabajo ahora."
  exit 0 ;;
verificar)
  programado || { echo "No hay ningún reinicio programado."; exit 1; }
  echo "El reinicio está programado: el equipo se reiniciará en unos minutos."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
