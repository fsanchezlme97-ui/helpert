#!/bin/bash
# Ver las impresoras y su estado (CUPS de macOS): cuáles hay, la predeterminada de la persona y si están en pausa, sin conexión
# o con trabajos en cola. Solo lectura: termina con 10.
set -u
usuario=${HP_USUARIO:-}

predeterminada() {  # la de la persona (leída como ella, por su ~/.cups/lpoptions) o, si no tiene, la del equipo
  d=""
  if [ "$(id -u)" -eq 0 ] && [ -n "$usuario" ] && [ "$usuario" != root ] && id -u "$usuario" >/dev/null 2>&1; then
    d=$(sudo -n -H -u "$usuario" lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
  fi
  [ -n "$d" ] || d=$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
  echo "$d"
}
estado() {  # «lista» o lo que le pasa, en una frase
  e=""
  lpstat -p "$1" 2>/dev/null | grep -q 'disabled' && e="en pausa"
  lpstat -l -p "$1" 2>/dev/null | grep -Eiq 'offline|not connected|unable to (connect|locate)|not responding|unavailable' && e="${e:+$e, }sin conexión"
  n=$(lpstat -o "$1" 2>/dev/null | grep -c .)
  [ "${n:-0}" -gt 0 ] && e="${e:+$e, }$n trabajo(s) en cola"
  echo "${e:-lista}"
}

case ${1:-} in
diagnosticar)
  command -v lpstat >/dev/null || { echo "Este equipo no tiene el sistema de impresión (CUPS) instalado."; exit 1; }
  lpstat -r 2>/dev/null | grep -q 'is running' || { echo "El servicio de impresión no responde: reinicia el Mac o avisa a soporte."; exit 10; }
  todas=$(lpstat -e 2>/dev/null)
  [ -n "$todas" ] || { echo "Este equipo no tiene impresoras instaladas; si necesitas una, soporte tiene que instalarla."; exit 10; }
  n=$(echo "$todas" | grep -c .); d=$(predeterminada)
  if [ -n "$d" ]; then echo "Hay $n impresora(s) instalada(s); la predeterminada es «$d»."
  else echo "Hay $n impresora(s) instalada(s) y ninguna es la predeterminada."; fi
  echo "$todas" | head -8 | while read -r p; do
    marca=""; [ "$p" = "$d" ] && marca=" (predeterminada)"
    echo "- $p$marca: $(estado "$p")."
  done
  [ "$n" -gt 8 ] && echo "… y $((n - 8)) más."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
