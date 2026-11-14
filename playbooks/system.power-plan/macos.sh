#!/bin/bash
# Poner el plan de energía equilibrado en macOS: modo de bajo consumo apagado (lowpowermode 0) y, en los Mac que tienen
# modos de energía, el automático (powermode 0), con batería y con cargador. Compatible con bash 3.2.
set -u
# ajustes que no están en automático: «lowpowermode 1», «powermode 1» o «powermode 2», en cualquier fuente de energía
fuera() { pmset -g custom 2>/dev/null | awk '($1 == "lowpowermode" || $1 == "powermode") && $2 != 0 {print $1, $2}' | sort -u; }
tiene() { pmset -g custom 2>/dev/null | awk -v k="$1" '$1 == k {f = 1} END {exit !f}'; }
modo() { case $1 in "lowpowermode 1"|"powermode 1") echo "bajo consumo" ;; "powermode 2") echo "alto rendimiento" ;; *) echo "$1" ;; esac; }

case ${1:-} in
diagnosticar)
  command -v pmset >/dev/null || { echo "No puedo revisar el plan de energía en este equipo."; exit 1; }
  tiene lowpowermode || tiene powermode || { echo "Este Mac no tiene modos de energía: siempre funciona en el modo normal."; exit 10; }
  f=$(fuera)
  [ -z "$f" ] && { echo "El plan de energía ya está en automático (equilibrado): el modo de bajo consumo está apagado."; exit 10; }
  echo "El Mac está en modo de $(modo "$(echo "$f" | head -1)"), al menos con batería o con cargador. Lo dejaría en automático (equilibrado)."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para cambiar el plan de energía."; exit 3; }
  exit 0 ;;
aplicar)
  if tiene lowpowermode; then pmset -a lowpowermode 0 2>/dev/null || { echo "No se pudo apagar el modo de bajo consumo."; exit 1; }; fi
  if tiene powermode; then pmset -a powermode 0 2>/dev/null || { echo "No se pudo poner el modo de energía en automático."; exit 1; }; fi
  echo "Apagué el modo de bajo consumo y dejé el plan de energía en automático (equilibrado)."
  exit 0 ;;
verificar)
  [ -z "$(fuera)" ] || { echo "El plan de energía sigue en modo de $(modo "$(fuera | head -1)")."; exit 1; }
  echo "El plan de energía está en automático (equilibrado)."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
