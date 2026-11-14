#!/bin/bash
# Revisar si FileVault cifra el disco y si el equipo tiene arranque seguro y chip de seguridad (Secure Enclave, que en
# Mac hace de TPM). Solo lectura: termina con 10. Activar FileVault lo hace soporte.
set -u
export LC_ALL=C
POLITICA=94b73556-2197-4702-82a8-3e1337dafbfb:AppleSecureBootPolicy
# una línea por protección; las que faltan empiezan con «- !»
revisar() {
  case $(fdesetup status 2>/dev/null) in
  *"FileVault is On"*) echo "- Disco: cifrado con FileVault." ;;
  *"in progress"*) echo "- Disco: FileVault lo está cifrando ahora." ;;
  *"FileVault is Off"*) echo "- !Disco: sin cifrar (FileVault apagado)." ;;
  *) echo "- Disco: no pude saber si FileVault está activo." ;;
  esac
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then
    echo "- Arranque seguro y chip de seguridad: integrados en el chip de Apple."
  elif system_profiler SPiBridgeDataType 2>/dev/null | grep -q T2; then
    echo "- Chip de seguridad: Apple T2."
    case $(nvram "$POLITICA" 2>/dev/null) in
    *%02*) echo "- Arranque seguro: activo (seguridad completa)." ;;
    *%01*) echo "- Arranque seguro: activo (seguridad media)." ;;
    *%00*) echo "- !Arranque seguro: apagado." ;;
    *) echo "- Arranque seguro: no pude saber su nivel." ;;
    esac
  else
    echo "- !Arranque seguro y chip de seguridad: este Mac no los tiene (es anterior al chip T2)."
  fi
}

case ${1:-} in
diagnosticar)
  r=$(revisar)
  n=$(printf '%s\n' "$r" | grep -c '^- !')
  if [ "$n" -eq 0 ]; then echo "El equipo tiene activas las protecciones que pude revisar."
  else echo "Al equipo le faltan $n protección(es) de seguridad."; fi
  printf '%s\n' "$r" | sed 's/^- !/- /'
  [ "$n" -eq 0 ] || echo "Activar FileVault o el arranque seguro lo hace soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
