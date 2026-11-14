#!/bin/bash
# Ver lo que arranca al inicio: los ítems de inicio de la persona (los que muestra Configuración > General > Ítems de
# inicio, según sfltool en macOS 13 o posterior), sus agentes (~/Library/LaunchAgents, leídos con su usuario) y los
# agentes y servicios de otros fabricantes para todo el equipo (/Library). Solo lectura: termina con 10.
set -u
usuario=${HP_USUARIO:-}
nombres() { sed 's/\.plist$//' | sort -u | head -"$1" | paste -sd, - | sed 's/,/, /g'; }
cuantos() { grep -c . ; }

case ${1:-} in
diagnosticar)
  uid=; casa=
  if [ -n "$usuario" ] && [ "$usuario" != root ]; then
    uid=$(id -u "$usuario" 2>/dev/null)
    casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  fi
  [ -n "$uid" ] || { echo "No pude revisar tus programas de inicio: no sé qué persona lo pide."; }
  if [ -n "$uid" ] && command -v sfltool >/dev/null; then
    # registros de su UID: Name, luego Type y Disposition; apps e ítems de inicio activados
    items=$(sfltool dumpbtm 2>/dev/null | awk -v u="$uid" '
      /Records for UID/ {mio = ($4 == u)}
      mio && $1 == "Name:" {n = $0; sub(/^ *Name: */, "", n)}
      mio && $1 == "Type:" {t = $0}
      mio && $1 == "Disposition:" {if (t ~ /app|login item/ && $0 ~ /enabled/ && n != "") print n; n = ""}' | nombres 8)
    if [ -n "$items" ]; then echo "Al iniciar tu sesión se abren: $items."
    else echo "No tienes ítems de inicio activados."; fi
  fi
  if [ -n "$casa" ] && [ -d "$casa/Library/LaunchAgents" ]; then
    mios=$(sudo -n -u "$usuario" ls "$casa/Library/LaunchAgents" 2>/dev/null | grep '\.plist$')
    n=$(printf '%s' "$mios" | cuantos)
    [ "$n" -gt 0 ] && echo "Programas de fondo tuyos ($n): $(printf '%s\n' "$mios" | nombres 5)."
  fi
  agentes=$(ls /Library/LaunchAgents 2>/dev/null | grep '\.plist$')
  servicios=$(ls /Library/LaunchDaemons 2>/dev/null | grep '\.plist$')
  na=$(printf '%s' "$agentes" | cuantos); ns=$(printf '%s' "$servicios" | cuantos)
  [ "$na" -gt 0 ] && echo "Programas de fondo de otros fabricantes para todas las sesiones ($na): $(printf '%s\n' "$agentes" | nombres 5)."
  [ "$ns" -gt 0 ] && echo "Servicios de otros fabricantes que arrancan con el equipo ($ns): $(printf '%s\n' "$servicios" | nombres 5)."
  echo "Para quitar un programa de tu inicio: Configuración del Sistema > General > Ítems de inicio. Los servicios los cambia soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
