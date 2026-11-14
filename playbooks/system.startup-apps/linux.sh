#!/bin/bash
# Ver lo que arranca al inicio: los programas que se abren al iniciar tu sesión (autostart: los tuyos, leídos con tu
# usuario, y los del sistema) y los servicios que más tardaron en el último arranque. Solo lectura: termina con 10.
set -u
usuario=${HP_USUARIO:-}
# Name= de cada .desktop que no esté oculto ni apagado
NOMBRES='FNR == 1 {if (n != "" && !h) print n; n = ""; h = 0}
  /^Name=/ && n == "" {n = substr($0, 6)}
  /^Hidden=true/ || /^X-GNOME-Autostart-enabled=false/ {h = 1}
  END {if (n != "" && !h) print n}'
como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }  # con el usuario de la persona
lista() { sort -u | head -8 | paste -sd, - | sed 's/,/, /g'; }

case ${1:-} in
diagnosticar)
  casa=; [ -n "$usuario" ] && [ "$usuario" != root ] && casa=$(getent passwd "$usuario" | cut -d: -f6)
  if [ -n "$casa" ] && [ -d "$casa/.config/autostart" ]; then
    mios=$(como find "$casa/.config/autostart" -maxdepth 1 -type f -name '*.desktop' \
           -exec awk "$NOMBRES" {} + 2>/dev/null | lista)
  else mios=; fi
  sistema=$(find /etc/xdg/autostart -maxdepth 1 -type f -name '*.desktop' -exec awk "$NOMBRES" {} + 2>/dev/null)
  if [ -n "$mios" ]; then echo "Al iniciar tu sesión se abren estos programas tuyos: $mios."
  elif [ -n "$casa" ]; then echo "No tienes programas propios que se abran al iniciar tu sesión."
  else echo "No pude revisar tus programas de inicio: no sé qué persona lo pide."; fi
  ns=$(printf '%s' "$sistema" | grep -c .)
  [ "$ns" -gt 0 ] && echo "Además, el sistema abre $ns programa(s) de fondo para todos (del escritorio, en su mayoría)."
  if command -v systemctl >/dev/null; then
    n=$(systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | grep -c .)
    echo "Arrancan $n servicio(s) con el equipo."
    total=$(systemd-analyze 2>/dev/null | head -1 | sed -n 's/.*= *//p')
    lentos=$(systemd-analyze blame --no-pager 2>/dev/null | head -3 | awk '{t = $1; for (i = 2; i < NF; i++) t = t " " $i; sub(/\.service$/, "", $NF); printf "%s%s (%s)", (NR > 1 ? ", " : ""), $NF, t}')
    [ -n "$total" ] && echo "El último arranque tardó $total."
    [ -n "$lentos" ] && echo "Los que más tardaron: $lentos."
  fi
  echo "Para quitar un programa de tu inicio, búscalo en la configuración de tu escritorio («Aplicaciones de inicio» o «Autoarranque»). Los servicios del sistema los cambia soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
