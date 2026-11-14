#!/bin/bash
# Revisar si el disco del sistema (y /home, si es aparte) está cifrado con LUKS, si el arranque seguro está activo y si
# hay chip TPM. Solo lectura: termina con 10. Activar el cifrado lo hace soporte.
set -u
SB=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
# una línea por protección; las que faltan empiezan con «- !»
disco() {  # $1 = punto de montaje, $2 = cómo llamarlo
  local src; src=$(findmnt -no SOURCE "$1" 2>/dev/null | sed 's/\[.*//')
  if [ ! -b "$src" ]; then echo "- $2: no pude saber si está cifrado (usa un sistema de archivos que no sé revisar)."
  elif lsblk -s -no TYPE "$src" 2>/dev/null | grep -qx crypt; then echo "- $2: cifrado (LUKS)."
  else echo "- !$2: sin cifrar."; fi
}
revisar() {
  disco / "Disco del sistema"
  h=$(findmnt -no SOURCE /home 2>/dev/null)
  [ -n "$h" ] && [ "$h" != "$(findmnt -no SOURCE / 2>/dev/null)" ] && disco /home "Partición /home"
  if [ ! -d /sys/firmware/efi ]; then echo "- !Arranque seguro: no tiene (el equipo arranca en modo antiguo, BIOS)."
  else
    case $(od -An -t u1 -j4 -N1 "$SB" 2>/dev/null | tr -d ' ') in
    1) echo "- Arranque seguro: activo." ;;
    0) echo "- !Arranque seguro: apagado." ;;
    *) echo "- Arranque seguro: no pude saber si está activo." ;;
    esac
  fi
  if [ -e /sys/class/tpm/tpm0 ]; then
    m=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null)
    echo "- Chip TPM: presente${m:+ (versión $m)}."
  else echo "- !Chip TPM: no se detecta (puede estar apagado en la configuración del equipo)."; fi
}

case ${1:-} in
diagnosticar)
  r=$(revisar)
  n=$(printf '%s\n' "$r" | grep -c '^- !')
  if [ "$n" -eq 0 ]; then echo "El equipo tiene activas las protecciones que pude revisar."
  else echo "Al equipo le faltan $n protección(es) de seguridad."; fi
  printf '%s\n' "$r" | sed 's/^- !/- /'
  [ "$n" -eq 0 ] || echo "Activar el cifrado, el arranque seguro o el TPM lo hace soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
