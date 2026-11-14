#!/bin/bash
# Impresora predeterminada del equipo (CUPS, lpadmin -d). HP_IMPRESORA ya viene validado; se busca sin distinguir mayúsculas.
set -u
pedida=${HP_IMPRESORA:-}
impresoras() { lpstat -e 2>/dev/null; }
elegida() { impresoras | grep -ixF -- "$pedida" | head -1 || true; }
parecida() { impresoras | grep -iF -- "$pedida" | head -1 || true; }
actual() { lpstat -d 2>/dev/null | sed -n 's/.*: //p'; }

case ${1:-} in
diagnosticar)
  command -v lpstat >/dev/null || { echo "Este equipo no tiene el sistema de impresión (CUPS) instalado."; exit 1; }
  [ -n "$(impresoras)" ] || { echo "Este equipo no tiene impresoras instaladas; soporte tiene que instalarla."; exit 1; }
  e=$(elegida); [ -n "$e" ] || e=$(parecida)
  [ -n "$e" ] || { echo "No encontré la impresora «$pedida». Las instaladas son: $(impresoras | paste -sd, | sed 's/,/, /g')."; exit 1; }
  [ "$(actual)" = "$e" ] && { echo "«$e» ya es la impresora predeterminada."; exit 10; }
  echo "La predeterminada ahora es «$(actual)»; la cambio por «$e»."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para cambiar la impresora predeterminada."; exit 3; }
  exit 0 ;;
aplicar)
  e=$(elegida); [ -n "$e" ] || e=$(parecida)
  lpadmin -d "$e" || { echo "No pude dejar «$e» como predeterminada."; exit 1; }
  echo "Dejé «$e» como impresora predeterminada."
  exit 0 ;;
verificar)
  e=$(elegida); [ -n "$e" ] || e=$(parecida)
  [ "$(actual)" = "$e" ] || { echo "La predeterminada no cambió."; exit 1; }
  echo "«$e» es ahora la impresora predeterminada. Si tu programa recuerda otra, elígela una vez al imprimir."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
