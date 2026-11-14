#!/bin/bash
# Expulsar una memoria USB o disco externo en macOS: dice qué programa la usa (lsof), escribe lo pendiente (sync) y
# la expulsa (diskutil eject). Nunca cierra programas: si está en uso, la persona los cierra. Solo volúmenes de
# /Volumes en discos externos o extraíbles, nunca el disco de arranque ni imágenes de disco.
set -u
arranque() { diskutil info / 2>/dev/null | sed -n -E 's/^ *(APFS Physical Store|Part of Whole): *(disk[0-9]+).*/\2/p' | head -1; }
# «disco|punto de montaje» de cada volumen abierto de un disco externo
montajes() {
  a=$(arranque)
  mount 2>/dev/null | sed -n -E 's#^/dev/disk[0-9s]+ on (/Volumes/.*) \([^()]*\)$#\1#p' | while IFS= read -r m; do
    i=$(diskutil info "$m" 2>/dev/null)
    echo "$i" | grep -q 'Protocol: *Disk Image' && continue
    echo "$i" | grep -Eq 'Device Location: *External|Removable Media: *Removable|Protocol: *USB|^ *Internal: *No' || continue
    d=$(echo "$i" | sed -n -E 's/^ *APFS Physical Store: *(disk[0-9]+).*/\1/p' | head -1)
    [ -n "$d" ] || d=$(echo "$i" | sed -n -E 's/^ *Part of Whole: *(disk[0-9]+).*/\1/p' | head -1)
    [ -n "$d" ] && [ "$d" != "$a" ] && echo "$d|$m"
  done
}
nombres() { echo "$1" | cut -d'|' -f2 | sed 's/^.*\///' | sort -u | sed 's/.*/«&»/' | paste -sd, - | sed 's/,/, /g'; }
# programas que tienen algo abierto en esas memorias (sin los de Spotlight, que macOS cierra solo al expulsar)
usando() {
  echo "$1" | while IFS='|' read -r _ m; do lsof -Fc "$m" 2>/dev/null; done | sed -n 's/^c//p' |
    grep -vE '^(mds|mds_stores|mdworker.*|fseventsd)$' | sort -u | paste -sd, - | sed 's/,/, /g'
}

case ${1:-} in
diagnosticar)
  command -v diskutil >/dev/null || { echo "No puedo ver los discos de este Mac."; exit 1; }
  l=$(montajes)
  [ -n "$l" ] || { echo "No hay ninguna memoria USB ni disco externo abierto: ya puedes desconectarlo."; exit 10; }
  echo "Memoria abierta: $(nombres "$l")."
  u=$(usando "$l")
  if [ -n "$u" ]; then echo "La está usando: $u. Guarda tu trabajo y cierra esos programas; después la expulso."
  else echo "Ningún programa la está usando: voy a terminar de guardar lo pendiente y expulsarla."; fi
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para expulsar la memoria."; exit 3; }
  l=$(montajes)
  [ -n "$l" ] || { echo "Ya no hay ninguna memoria abierta."; exit 3; }
  u=$(usando "$l")
  [ -z "$u" ] || { echo "Todavía la está usando: $u. Guarda tu trabajo, cierra esos programas y vuelve a intentarlo."; exit 3; }
  exit 0 ;;
aplicar)
  l=$(montajes)
  [ -n "$l" ] || { echo "No había ninguna memoria abierta: ya puedes desconectarla."; exit 0; }
  sync
  for d in $(echo "$l" | cut -d'|' -f1 | sort -u); do
    diskutil eject "$d" >/dev/null 2>&1 && continue
    u=$(usando "$l")
    echo "No pude expulsar la memoria: ${u:+la está usando $u; }cierra los programas que tengan archivos de ella abiertos y vuelve a intentarlo."
    exit 1
  done
  echo "Guardé lo pendiente y expulsé $(nombres "$l")."
  exit 0 ;;
verificar)
  [ -z "$(montajes)" ] || { echo "La memoria sigue abierta: no la desconectes todavía."; exit 1; }
  echo "Ya puedes desconectar la memoria con seguridad."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
