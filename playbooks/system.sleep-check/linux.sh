#!/bin/bash
# Revisar la suspensión: qué programa la bloquea (bloqueos de logind), si está desactivada, qué hace la tapa y qué
# dispositivos USB pueden despertar al equipo. Solo lectura: termina con 10.
set -u
LOGIN1=(org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager)
# programas con un bloqueo «block» sobre la suspensión (sleep) o la suspensión por inactividad (idle); no cuenta los de
# la tapa y los botones, que el escritorio (KDE, GNOME) toma siempre. ListInhibitors da (qué, quién, por qué, modo, uid, pid)
bloquean() {
  busctl call "${LOGIN1[@]}" ListInhibitors 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | paste - - - - |
    awk -F'\t' '$4 == "block" {n = split($1, q, ":"); for (i = 1; i <= n; i++) if (q[i] == "sleep" || q[i] == "idle") {print $2; break}}' | sort -u | head -5 | paste -sd, | sed 's/,/, /g'
}
case ${1:-} in
diagnosticar)
  command -v systemctl >/dev/null && command -v busctl >/dev/null || { echo "No puedo revisar la suspensión en este equipo (no usa systemd)."; exit 1; }
  avisos=()
  if [ "$(systemctl is-enabled suspend.target 2>/dev/null)" = masked ] || [ "$(systemctl is-enabled sleep.target 2>/dev/null)" = masked ]; then
    avisos+=("La suspensión está desactivada en este equipo. Si no fue a propósito, pide a soporte que la active.")
  fi
  b=$(bloquean)
  [ -n "$b" ] && avisos+=("Ahora impide la suspensión: $b. Ciérralo o termina lo que esté haciendo (una descarga, una llamada, un video).")
  tapa=$(busctl get-property "${LOGIN1[@]}" HandleLidSwitch 2>/dev/null | awk '{gsub(/"/, "", $2); print $2}')
  if [ "$tapa" = ignore ] || [ "$tapa" = lock ]; then
    avisos+=("Al cerrar la tapa el equipo no se suspende (está configurado para «$tapa»); por eso gasta batería.")
  fi
  # dispositivos USB con permiso para despertar al equipo (un mouse que se mueve lo despierta)
  despiertan=$(for d in /sys/bus/usb/devices/*; do
      [ "$(cat "$d/power/wakeup" 2>/dev/null)" = enabled ] && cat "$d/product" 2>/dev/null
    done | grep -iv 'hub\|controller' | sort -u | head -3 | paste -sd, | sed 's/,/, /g')
  if [ ${#avisos[@]} -eq 0 ]; then echo "La suspensión está activa y ningún programa la está impidiendo ahora."
  else echo "Encontré lo que puede estar fallando con la suspensión:"; printf -- '- %s\n' "${avisos[@]}"; fi
  [ -n "$despiertan" ] && echo "Pueden despertar al equipo: $despiertan. Si se despierta solo, desconéctalo o no lo muevas antes de suspender."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
