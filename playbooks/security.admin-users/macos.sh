#!/bin/bash
# Ver qué cuentas son administradoras en macOS (grupo admin) y, si el Mac está unido a un dominio, qué grupos de la
# empresa también lo son. Solo lectura: termina con 10. Dar o quitar permisos lo hace soporte.
set -u
export LC_ALL=C

case ${1:-} in
diagnosticar)
  l=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null | sed 's/^GroupMembership://' | tr ' ' '\n' | grep -v '^$' | grep -vx root | sort -u)
  ad=$(dsconfigad -show 2>/dev/null | sed -n 's/^[[:space:]]*Allowed admin groups[[:space:]]*=[[:space:]]*//p' | grep -v 'not set')
  if [ -z "$l" ] && [ -z "$ad" ]; then echo "Ninguna cuenta de persona es administradora en este Mac."; exit 10; fi
  [ -n "$l" ] && { echo "Estas $(printf '%s\n' "$l" | wc -l | tr -d ' ') cuenta(s) son administradoras en este Mac:"; printf '%s\n' "$l" | head -7 | sed 's/^/- /'; }
  [ -n "$ad" ] && echo "También lo son los miembros de estos grupos de la empresa: $ad."
  echo "Dar o quitar permisos lo hace soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
