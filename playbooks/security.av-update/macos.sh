#!/bin/bash
# Actualizar XProtect (el antivirus de macOS): las firmas que ofrece la actualización de software de Apple y, desde
# macOS 15, las que se bajan con «xprotect update». No instala otro antivirus ni actualiza macOS.
set -u
export LC_ALL=C
limite() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # macOS no trae timeout
tiene_xp() { command -v xprotect >/dev/null; }
version() {
  local v=""
  tiene_xp && v=$(xprotect version 2>/dev/null | grep -Eo '[0-9]{4,}' | head -1)
  [ -n "$v" ] || v=$(defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info CFBundleShortVersionString 2>/dev/null)
  echo "$v"
}
# versión que ofrece Apple por la vía de macOS 15 («xprotect check»); nada si no responde
disponible() { tiene_xp && limite 40 xprotect check 2>/dev/null | sed -n 's/.*version: *\([0-9][0-9]*\).*/\1/p' | head -1; }
# actualizaciones de XProtect pendientes en la actualización de software
etiquetas() { limite 100 softwareupdate -l --include-config-data 2>/dev/null | sed -n 's/^.*Label: *//p' | grep '^XProtect'; }
mas_nueva() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -gt "$2" ] 2>/dev/null; }

case ${1:-} in
diagnosticar)
  v=$(version); e=$(etiquetas); d=$(disponible)
  [ -n "$v" ] || { echo "No encuentro XProtect en este equipo: avisa a soporte."; exit 1; }
  if [ -n "$e" ] || mas_nueva "$d" "$v"; then
    echo "XProtect tiene la versión $v y Apple ofrece firmas más nuevas${d:+ (versión $d)}. Puedo descargarlas ahora."; exit 0
  fi
  if tiene_xp && [ -z "$d" ]; then
    echo "XProtect tiene la versión $v. No pude confirmar con Apple si hay firmas más nuevas; puedo pedírselas ahora."; exit 0
  fi
  echo "XProtect está al día (versión $v)."
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para actualizar XProtect."; exit 3; }
  exit 0 ;;
aplicar)
  ok=0; fallo=0
  for l in $(etiquetas); do
    if limite 150 softwareupdate -i "$l" --include-config-data >/dev/null 2>&1; then ok=1; else fallo=1; fi
  done
  if tiene_xp; then
    if limite 60 xprotect update >/dev/null 2>&1; then ok=1; else fallo=1; fi
  fi
  [ "$ok" = 1 ] || [ "$fallo" = 0 ] || { echo "No se pudieron descargar las firmas de XProtect; puede que no haya internet o que la red bloquee los servidores de Apple."; exit 1; }
  echo "Pedí a Apple las firmas nuevas de XProtect (ahora tiene la versión $(version))."
  exit 0 ;;
verificar)
  v=$(version); d=$(disponible)
  if [ -n "$(etiquetas)" ] || mas_nueva "$d" "$v"; then echo "XProtect todavía tiene firmas pendientes (versión $v)."; exit 1; fi
  if tiene_xp && [ -z "$d" ]; then echo "XProtect tiene la versión $v. No pude confirmar con Apple si hay una más nueva."; exit 0; fi
  echo "XProtect está al día (versión $v)."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
