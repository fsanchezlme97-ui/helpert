#!/bin/bash
# Reiniciar el escritorio de la persona sin cerrar su sesión ni sus programas. Solo donde se puede hacer sin riesgo:
# KDE Plasma, cuya barra y escritorio (plasmashell) son un servicio de su sesión. En GNOME (Wayland) reiniciar el
# escritorio cierra la sesión entera, así que no se hace. Todo corre con el usuario de la persona, nunca como root.
set -u
UNIDAD=plasma-plasmashell.service
usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)
sesion() { runuser -u "$usuario" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para actuar en tu sesión."; return 1; }
  [ -d "/run/user/$uid/systemd" ] || { echo "No encontré tu sesión abierta en este equipo."; return 1; }
}
activo() { [ "$(sesion systemctl --user is-active "$UNIDAD" 2>/dev/null)" = active ]; }
no_se_puede() {
  if pgrep -u "$uid" -x plasmashell >/dev/null; then
    echo "Tu escritorio KDE no corre como servicio de la sesión, así que no puedo reiniciarlo sin riesgo. Cierra sesión y vuelve a entrar."
  elif pgrep -u "$uid" -x gnome-shell >/dev/null; then
    echo "En GNOME no se puede reiniciar el escritorio sin cerrar tus programas. Guarda tu trabajo, cierra sesión y vuelve a entrar."
  else
    echo "Tu escritorio no se puede reiniciar desde aquí sin cerrar tus programas. Guarda tu trabajo, cierra sesión y vuelve a entrar."
  fi
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  activo || { no_se_puede; exit 3; }
  echo "Tu escritorio es KDE Plasma. Puedo reiniciar la barra de tareas y el escritorio; tus programas abiertos no se cierran."
  exit 0 ;;
comprobar)
  puedo || exit 3
  activo || { no_se_puede; exit 3; }
  exit 0 ;;
aplicar)
  sesion systemctl --user restart "$UNIDAD" 2>/dev/null || { echo "No se pudo reiniciar el escritorio."; exit 1; }
  echo "Reinicié la barra de tareas y el escritorio. Tus programas siguen abiertos."
  exit 0 ;;
verificar)
  for _ in 1 2 3 4 5; do activo && break; sleep 1; done
  activo || { echo "El escritorio no volvió a arrancar. Cierra sesión y vuelve a entrar; si sigue igual, avisa a soporte."; exit 1; }
  echo "La barra de tareas y el escritorio volvieron a funcionar."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
