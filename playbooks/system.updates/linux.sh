#!/bin/bash
# Revisar las actualizaciones pendientes (apt, dnf o pacman) y si hace falta reiniciar. Solo lectura: termina con 10.
# No se instala nada ni se toca la base de paquetes: apt simula con las listas que ya tiene (y se dice de cuándo son),
# dnf refresca su caché de metadatos si caducó (no toca paquetes) y pacman usa checkupdates (copia aparte de la base) o, sin él, la base local.
set -u
pendientes() {  # una línea por paquete: «nombre» (con «seguridad» al lado si lo es)
  if command -v apt-get >/dev/null; then
    apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | awk '/^Inst / {print $2 (/-security/ ? " (seguridad)" : "")}'
  elif command -v dnf >/dev/null; then
    dnf -q check-update 2>/dev/null | awk 'NF == 3 && $1 ~ /\./ {sub(/\.[^.]*$/, "", $1); print $1}'
  elif command -v pacman >/dev/null; then
    if command -v checkupdates >/dev/null; then checkupdates 2>/dev/null | awk '{print $1}'
    else pacman -Qu 2>/dev/null | awk '{print $1}'; fi
  fi
}
reinicio() {  # Debian/Ubuntu lo anotan; Fedora tiene needs-restarting; en todos, el núcleo en uso ya no está instalado
  [ -e /run/reboot-required ] && return 0
  [ -d "/lib/modules/$(uname -r)" ] || return 0
  command -v needs-restarting >/dev/null && ! needs-restarting -r >/dev/null 2>&1 && return 0
  return 1
}

case ${1:-} in
diagnosticar)
  command -v apt-get >/dev/null || command -v dnf >/dev/null || command -v pacman >/dev/null ||
    { echo "No reconozco el gestor de paquetes de este sistema."; exit 1; }
  lista=$(pendientes)
  n=$(printf '%s' "$lista" | grep -c .)
  seg=$(printf '%s\n' "$lista" | grep -c 'seguridad')
  if [ "$n" -eq 0 ]; then echo "El sistema está al día: no hay actualizaciones pendientes."
  else
    echo "Hay $n actualización(es) pendiente(s)$( [ "$seg" -gt 0 ] && echo ", $seg de seguridad"):"
    printf '%s\n' "$lista" | head -6 | sed 's/^/- /'
    [ "$n" -gt 6 ] && echo "- y $((n - 6)) más."
    echo "Instalarlas lo programa soporte."
  fi
  if command -v apt-get >/dev/null; then
    edad=$(find /var/lib/apt/lists -maxdepth 1 -name '*Release' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    [ -n "$edad" ] && echo "La lista de actualizaciones es de hace $(( ($(date +%s) - edad) / 86400 )) día(s)."
  elif command -v pacman >/dev/null && ! command -v checkupdates >/dev/null; then
    echo "La lista sale de la última vez que el sistema buscó actualizaciones; puede no estar al día."
  fi
  reinicio && echo "Además, hay un reinicio pendiente para terminar de aplicar actualizaciones ya instaladas."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
