#!/bin/bash
# Reiniciar el equipo: programa un reinicio en 2 minutos (systemd-logind lo guarda) y avisa en la pantalla de la persona.
# El script termina enseguida: el reinicio lo hace el sistema después, no este proceso.
set -u
AVISO="El equipo se reiniciará en 2 minutos. Guarda tu trabajo y cierra los programas."
usuario=${HP_USUARIO:-}

programado() { grep -qs '^MODE=reboot' /run/systemd/shutdown/scheduled; }
pendiente() {  # actualización que pide reiniciar: Debian/Ubuntu lo anotan; en el resto, el núcleo en uso ya no está instalado
  [ -e /run/reboot-required ] || [ ! -d "/lib/modules/$(uname -r)" ]
}
avisar() {  # notificación en el escritorio de la persona, con su usuario y su bus de sesión; sin sesión, nada
  uid=$(id -u "$usuario" 2>/dev/null) || return 1
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -S "/run/user/$uid/bus" ]; } || return 1
  bus="unix:path=/run/user/$uid/bus"
  if command -v notify-send >/dev/null; then
    timeout 10 runuser -u "$usuario" -- env DBUS_SESSION_BUS_ADDRESS="$bus" \
      notify-send -u critical -a Helpert "Reinicio en 2 minutos" "$AVISO" </dev/null >/dev/null 2>&1
  elif command -v gdbus >/dev/null; then
    timeout 10 runuser -u "$usuario" -- env DBUS_SESSION_BUS_ADDRESS="$bus" gdbus call --session \
      --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.Notify Helpert 0 '' "Reinicio en 2 minutos" "$AVISO" '[]' '{"urgency": <byte 2>}' 0 \
      </dev/null >/dev/null 2>&1
  else return 1; fi
}

case ${1:-} in
diagnosticar)
  programado && { echo "Ya hay un reinicio programado en este equipo."; exit 10; }
  dias=$(awk '{print int($1 / 86400)}' /proc/uptime)
  echo "El equipo lleva $dias día(s) sin reiniciarse."
  pendiente && echo "Hay una actualización instalada que necesita reiniciar para terminar."
  echo "Puedo programar un reinicio en 2 minutos, con un aviso en tu pantalla para que guardes tu trabajo."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el equipo."; exit 3; }
  command -v shutdown >/dev/null || { echo "Este equipo no tiene la orden para programar el reinicio."; exit 3; }
  exit 0 ;;
aplicar)
  shutdown -r +2 "$AVISO" </dev/null >/dev/null 2>&1 || { echo "El sistema no aceptó programar el reinicio."; exit 1; }
  echo "Programé el reinicio para las $(date -d '+2 min' +%H:%M), dentro de 2 minutos. Guarda tu trabajo y cierra los programas."
  avisar || echo "No pude mostrarte el aviso en la pantalla: guarda tu trabajo ahora."
  exit 0 ;;
verificar)
  programado || { echo "No hay ningún reinicio programado."; exit 1; }
  echo "El reinicio está programado: el equipo se reiniciará en unos minutos."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
