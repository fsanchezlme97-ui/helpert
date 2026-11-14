#!/bin/bash
# Revisar errores del sistema de archivos sin cambiar nada (solo lectura: termina con 10). Un disco montado no se
# puede revisar a fondo con fsck, así que se mira lo que el sistema ya sabe: si quedó en solo lectura, la marca de
# errores de ext4, los contadores de btrfs y los errores del disco en el registro del núcleo desde que arrancó.
set -u
TIPOS='^(ext[234]|xfs|btrfs|f2fs|jfs)$'

case ${1:-} in
diagnosticar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para revisar el disco."; exit 3; }
  command -v findmnt >/dev/null || { echo "Falta la herramienta findmnt para ver los discos montados."; exit 1; }
  ro="" ext="" btr=""
  for m in / /home; do
    read -r tipo opc <<< "$(findmnt -no FSTYPE,OPTIONS -T "$m" 2>/dev/null)"
    [[ ${tipo:-} =~ $TIPOS ]] && [[ ,${opc:-}, == *,ro,* ]] && ro="$ro $m"
  done
  while read -r dev dest; do
    [ -b "$dev" ] && command -v tune2fs >/dev/null || continue
    tune2fs -l "$dev" 2>/dev/null | grep -Eqi '^(Filesystem state:.*error|FS Error count: *[1-9])' && ext="$ext $dest"
  done < <(findmnt -rn -t ext2,ext3,ext4 -o SOURCE,TARGET 2>/dev/null)
  if command -v btrfs >/dev/null; then
    while read -r dest; do
      btrfs device stats -c "$dest" >/dev/null 2>&1 || btr="$btr $dest"
    done < <(findmnt -rn -t btrfs -o TARGET 2>/dev/null | sort -u)
  fi
  if command -v journalctl >/dev/null; then log=$(journalctl -k -b -p err --no-pager -q 2>/dev/null); else log=$(dmesg 2>/dev/null); fi
  es=$(grep -Eci 'EXT4-fs error|BTRFS (error|critical)|XFS .*(corrupt|error)|Buffer I/O error|I/O error, dev|critical medium error' <<< "$log")
  if [ -z "$ro$ext$btr" ] && [ "${es:-0}" -eq 0 ]; then
    echo "No encontré errores en el disco: el sistema de archivos está bien y no hace falta repararlo."
    echo "Si un programa dice que un archivo está dañado, puede ser solo ese archivo: prueba con una copia de seguridad."
    exit 10
  fi
  echo "Encontré señales de errores en el disco."
  [ -n "$ro" ] && echo "-$ro: está en solo lectura; el sistema lo protegió al encontrar un error."
  [ -n "$ext" ] && echo "-$ext: tiene marcados errores; se revisa y repara solo al reiniciar."
  [ -n "$btr" ] && echo "-$btr: registró errores de lectura o escritura."
  [ "${es:-0}" -gt 0 ] && echo "- El sistema anotó $es error(es) del disco desde que encendiste el equipo."
  if [ -n "$ro$ext" ]; then echo "Guarda lo que tengas abierto y reinicia: al arrancar se revisa el disco. Si el aviso vuelve, pide a soporte que lo revise."
  else echo "Haz copia de tus archivos importantes y pide a soporte que revise el disco: podría estar fallando (también puedes usar «Revisar la salud del disco»)."; fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
