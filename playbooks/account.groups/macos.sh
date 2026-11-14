#!/bin/bash
# Ver a qué grupos pertenece la cuenta de la persona, locales y del dominio si el Mac está unido a uno. Los nombres
# salen de dscacheutil, uno por número de grupo, para no partir los nombres con espacios. No se muestran los grupos
# internos de macOS (los que empiezan con «_» o «com.apple.»). Solo lectura: termina con 10.
set -u
export LC_ALL=C
usuario=${HP_USUARIO:-}

case ${1:-} in
diagnosticar)
  { [ -n "$usuario" ] && id "$usuario" >/dev/null 2>&1; } || { echo "No sé qué persona lo pide."; exit 3; }
  l=$(for g in $(id -G "$usuario" 2>/dev/null); do
        n=$(dscacheutil -q group -a gid "$g" 2>/dev/null | awk -F': ' '$1 == "name" {print $2; exit}'); echo "${n:-grupo $g}"
      done | grep -v '^_' | grep -v '^com\.apple\.' | sort -u)
  n=$(printf '%s\n' "$l" | grep -c .)
  echo "La cuenta «${usuario}» pertenece a $n grupo(s), sin contar los internos de macOS:"
  printf '%s\n' "$l" | paste -sd, - | sed 's/,/, /g'
  echo "Si te acaban de agregar a un grupo, cierra sesión y vuelve a entrar para que cuente. Dar accesos lo hace soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
