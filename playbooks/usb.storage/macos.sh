#!/bin/bash
# Abrir una memoria USB o disco externo en macOS: si el equipo lo detecta pero un volumen no está montado, lo monta
# con diskutil (lo mismo que hace macOS al conectarla), por su identificador. Nunca formatea, repara ni desbloquea
# volúmenes cifrados (eso pide la contraseña a la persona). Ni discos internos, ni imágenes de disco.
set -u
export LC_ALL=C
dato() { printf '%s\n' "$1" | sed -n "s/^ *$2: *//p" | head -1; }
# disco físico de un «diskutil info» (el del contenedor APFS o el de la partición)
fisico() {
  local d; d=$(printf '%s\n' "$1" | sed -n -E 's/^ *APFS Physical Store: *(disk[0-9]+).*/\1/p' | head -1)
  [ -n "$d" ] || d=$(printf '%s\n' "$1" | sed -n -E 's/^ *Part of Whole: *(disk[0-9]+).*/\1/p' | head -1)
  echo "$d"
}
# «id|estado|nombre» de cada volumen de un disco externo o extraíble; estado: abierto, cerrado o cifrado
volumenes() {
  a=$(fisico "$(diskutil info / 2>/dev/null)")
  for id in $(diskutil list 2>/dev/null | grep -oE 'disk[0-9]+(s[0-9]+)?$' | sort -u); do
    i=$(diskutil info "$id" 2>/dev/null) || continue
    printf '%s\n' "$i" | grep -q 'Protocol: *Disk Image' && continue
    printf '%s\n' "$i" | grep -Eq 'Device Location: *External|Removable Media: *Removable|Protocol: *USB|^ *Internal: *No' || continue
    [ -n "$(dato "$i" 'File System Personality')" ] || continue  # sin formato que macOS lea, o un disco con particiones
    printf '%s\n' "$i" | grep -Eq 'Partition Type: *(EFI|Apple_Boot)' && continue
    n=$(dato "$i" 'Volume Name')
    [ "$n" = EFI ] && continue
    case $(dato "$i" 'File System Personality') in  # volúmenes de sistema de un disco con macOS
    *APFS*) case $n in Preboot|Recovery|VM|Update|iSCPreboot|xART|Hardware) continue ;; esac ;;
    esac
    [ -n "$a" ] && [ "$(fisico "$i")" = "$a" ] && continue  # nunca el disco de arranque
    if printf '%s\n' "$i" | grep -q '^ *Mounted: *Yes'; then e=abierto
    elif printf '%s\n' "$i" | grep -q '^ *Locked: *Yes'; then e=cifrado
    else e=cerrado; fi
    echo "$id|$e|${n:-sin nombre}"
  done
}
de() { printf '%s\n' "$1" | awk -F'|' -v e="$2" '$2 == e'; }
nombres() { printf '%s\n' "$1" | cut -d'|' -f3 | sort -u | sed 's/.*/«&»/' | paste -sd, - | sed 's/,/, /g'; }
externos() { diskutil list external physical 2>/dev/null | grep -c '^/dev/disk'; }

case ${1:-} in
diagnosticar)
  command -v diskutil >/dev/null || { echo "No puedo ver los discos de este Mac."; exit 1; }
  v=$(volumenes)
  if [ -z "$v" ]; then
    [ "$(externos)" -gt 0 ] && { echo "El equipo detecta la memoria, pero no reconoce su formato: puede estar dañada o tener un formato que macOS no lee. No la formateo: si tiene archivos importantes, avisa a soporte."; exit 10; }
    echo "El equipo no detecta ninguna memoria USB ni disco externo. Desconéctala, espera 5 segundos y conéctala en otro puerto; si sigue sin aparecer, puede estar dañada."
    exit 10
  fi
  c=$(de "$v" cifrado)
  [ -n "$c" ] && echo "La memoria $(nombres "$c") está cifrada: ábrela desde el Finder con su contraseña (yo no la pido ni la desbloqueo)."
  s=$(de "$v" cerrado)
  [ -n "$s" ] || { [ -n "$c" ] || echo "La memoria está conectada y abierta: búscala en el Finder, en la barra lateral."; exit 10; }
  echo "El equipo detecta $(nombres "$s"), pero no está abierta."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para abrir la memoria."; exit 3; }
  [ -n "$(de "$(volumenes)" cerrado)" ] || { echo "Ya no hay ninguna memoria sin abrir."; exit 3; }
  exit 0 ;;
aplicar)
  s=$(de "$(volumenes)" cerrado)
  [ -n "$s" ] || { echo "No había ninguna memoria sin abrir."; exit 0; }
  printf '%s\n' "$s" | while IFS='|' read -r id _ n; do
    if diskutil mount "$id" >/dev/null 2>&1; then echo "- Abrí «${n}»."; else echo "- No pude abrir «${n}»."; fi
  done
  exit 0 ;;
verificar)
  s=$(de "$(volumenes)" cerrado)
  [ -z "$s" ] || { echo "No pude abrir $(nombres "$s"): puede tener un formato que el equipo no lee o estar dañada."; exit 1; }
  echo "La memoria está abierta: búscala en el Finder, en la barra lateral."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
