#!/bin/bash
# Ver por qué un programa se cierra solo: busca en el registro del sistema (journal: fallos del kernel, volcados de
# systemd-coredump y cierres por falta de memoria) y en /var/crash (Ubuntu) sus cierres inesperados de los últimos
# 14 días. Solo lectura: termina con 10. HP_PROGRAMA ya viene validado; se compara como texto literal.
set -u
prog=$(echo "${HP_PROGRAMA:-}" | tr 'A-Z' 'a-z')
# nombres que la gente dice → nombre del proceso
case $prog in
  libreoffice|word|excel|powerpoint|writer|calc|impress) prog=soffice ;;
  chrome|google-chrome) prog=chrome ;;
  edge|msedge|microsoft-edge) prog=msedge ;;
esac

# líneas del registro con el programa: «fecha mensaje»
eventos() {
  command -v journalctl >/dev/null || return 0
  journalctl -q --no-pager --since=-14d -o short-iso _TRANSPORT=kernel + SYSLOG_IDENTIFIER=systemd-coredump 2>/dev/null |
    grep -E 'segfault at|general protection|trap divide|dumped core|Killed process' | grep -iF -- "$prog"
}
informes() { find /var/crash -maxdepth 1 -type f -name '*.crash' -mtime -14 -iname "*${prog}*" 2>/dev/null; }

case ${1:-} in
diagnosticar)
  [ ${#prog} -ge 3 ] || { echo "Necesito el nombre del programa (al menos 3 letras)."; exit 1; }
  ev=$(eventos); n=$(printf '%s' "$ev" | grep -c .)
  oom=$(printf '%s' "$ev" | grep -c 'Killed process')
  c=$(informes | grep -c .)
  if [ "$n" -eq 0 ] && [ "$c" -eq 0 ]; then
    echo "No encontré cierres inesperados de «${HP_PROGRAMA:-}» en los registros de los últimos 14 días."
    echo "Si se cierra sin dejar rastro, puede ser un problema de su configuración: restablecerlo o reinstalarlo suele ayudar. Si sigue, avisa a soporte."
    exit 10
  fi
  [ "$n" -gt 0 ] || n=$c
  veces="$n veces"; [ "$n" -eq 1 ] && veces="1 vez"
  ultima=$(printf '%s\n' "$ev" | tail -1 | cut -c1-16 | sed -E 's/^[0-9]{4}-([0-9]{2})-([0-9]{2})T(.*)/\2\/\1 a las \3/')
  echo "«${HP_PROGRAMA:-}» se cerró de forma inesperada $veces en los últimos 14 días${ultima:+; la última, el $ultima}."
  if [ "$oom" -gt 0 ]; then
    echo "$oom de esas veces lo cerró el sistema porque se quedó sin memoria: cierra otros programas o pestañas mientras lo usas. Si pasa seguido, avisa a soporte."
  else
    echo "Fue un fallo del propio programa: actualizarlo o restablecer su configuración suele ayudar. Si sigue, avisa a soporte."
  fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
