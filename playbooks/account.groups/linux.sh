#!/bin/bash
# Ver a qué grupos pertenece la cuenta de la persona, locales y del dominio (si el equipo usa SSSD o winbind).
# Los nombres salen de getent, uno por número de grupo, para no partir los nombres con espacios. Solo lectura: 10.
set -u
usuario=${HP_USUARIO:-}

case ${1:-} in
diagnosticar)
  { [ -n "$usuario" ] && id "$usuario" >/dev/null 2>&1; } || { echo "No sé qué persona lo pide."; exit 3; }
  l=$(for g in $(id -G "$usuario" 2>/dev/null); do n=$(getent group "$g" | cut -d: -f1); echo "${n:-grupo $g}"; done | sort -u)
  n=$(printf '%s\n' "$l" | grep -c .)
  echo "La cuenta «$usuario» pertenece a $n grupo(s):"
  printf '%s\n' "$l" | paste -sd, - | sed 's/,/, /g'
  echo "Si te acaban de agregar a un grupo, cierra sesión y vuelve a entrar para que cuente. Dar accesos lo hace soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
