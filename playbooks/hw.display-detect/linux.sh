#!/bin/bash
# Detectar un monitor externo: qué salidas de video ve el kernel (/sys/class/drm) y pedirle a cada una que vuelva a
# buscar pantallas (escribir «detect» en su estado). No cambia la resolución ni el orden de las pantallas.
set -u
DRM=/sys/class/drm
salidas() {  # «nombre estado» de cada salida (card0-HDMI-A-1 connected)
  for s in "$DRM"/card*-*/status; do
    [ -r "$s" ] || continue
    n=$(basename "$(dirname "$s")"); case $n in *Writeback*) continue ;; esac
    echo "$n $(cat "$s" 2>/dev/null)"
  done
}
interna() { case $1 in *-eDP-*|*-LVDS-*|*-DSI-*) return 0 ;; esac; return 1; }
# nombre para la persona: «pantalla del equipo», «HDMI», «DisplayPort»…
tipo() { echo "$1" | sed -E 's/^card[0-9]+-//; s/-[0-9]+$//; s/^(eDP|LVDS|DSI).*/pantalla del equipo/; s/^HDMI.*/HDMI/; s/^DP$/DisplayPort/; s/^DVI.*/DVI/; s/^Virtual$/pantalla virtual/'; }
# 0 si se ven las que hacen falta: con pantalla propia, una externa más; sin ella (un equipo de escritorio), dos
bien() {
  int=0 ext=0
  while read -r n e; do
    [ "$e" = connected ] || continue
    if interna "$n"; then int=$((int + 1)); else ext=$((ext + 1)); fi
  done <<< "$(salidas)"
  [ "$ext" -ge 1 ] && { [ "$int" -ge 1 ] || [ "$ext" -ge 2 ]; }
}
vistas() { salidas | awk '$2 == "connected" {print $1}' | while read -r n; do tipo "$n"; done | paste -sd, - | sed 's/,/, /g'; }

case ${1:-} in
diagnosticar)
  [ -n "$(salidas)" ] || { echo "No encuentro salidas de video que pueda revisar en este equipo."; exit 3; }
  v=$(vistas)
  if bien; then
    echo "El equipo detecta estas pantallas: $v."
    echo "Si una se ve negra, actívala en la configuración de pantalla del escritorio (elige «Extender» o «Duplicar»); en muchos escritorios se abre con la tecla Super+P."
    exit 10
  fi
  if [ -n "$v" ]; then echo "El equipo solo detecta: $v. No ve el monitor externo."; else echo "El equipo no detecta ninguna pantalla conectada."; fi
  echo "Voy a pedirle a la tarjeta de video que vuelva a buscar pantallas."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para buscar pantallas."; exit 3; }
  [ -n "$(salidas)" ] || { echo "No encuentro salidas de video en este equipo."; exit 3; }
  exit 0 ;;
aplicar)
  for s in "$DRM"/card*-*/status; do [ -w "$s" ] && { echo detect > "$s"; } 2>/dev/null; done
  sleep 3
  echo "Le pedí a la tarjeta de video que vuelva a buscar pantallas."
  exit 0 ;;
verificar)
  bien || { echo "Sigue sin detectar el monitor externo. Revisa que esté encendido, con el cable bien puesto en los dos lados y en la entrada correcta (HDMI, DisplayPort); prueba otro cable o puerto. Si usas una base o adaptador, desconéctalo y conéctalo."; exit 1; }
  echo "El equipo detecta estas pantallas: $(vistas). Si una se ve negra, actívala en la configuración de pantalla («Extender» o «Duplicar»)."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
