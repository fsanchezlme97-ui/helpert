#!/bin/bash
# Impresora predeterminada (CUPS de macOS). La del equipo se cambia con lpadmin -d; además, como la persona (sudo -u),
# se fija en su ~/.cups/lpoptions (lpoptions -d) y se apaga «Impresora predeterminada: última impresora usada»
# (org.cups.PrintingPrefs UseLastPrinter, que libcups lee de sus preferencias y que sin valor vale «sí»), porque si no
# macOS la cambia sola por la última que usó. HP_IMPRESORA ya viene validado; se busca sin distinguir mayúsculas.
set -u
pedida=${HP_IMPRESORA:-}
usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)

impresoras() { lpstat -e 2>/dev/null; }
elegida() {
  e=$(impresoras | grep -ixF -- "$pedida" | head -1)
  [ -n "$e" ] || e=$(impresoras | grep -iF -- "$pedida" | head -1)
  echo "$e"
}
como() { sudo -n -H -u "$usuario" "$@"; }
# la que ve la persona al imprimir (con sus preferencias), como en print.status
actual() { como lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p'; }
fija() { [ "$(como defaults read org.cups.PrintingPrefs UseLastPrinter 2>/dev/null)" = 0 ]; }
no_puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 0; }
  [ -n "$pedida" ] || { echo "Necesito el nombre de la impresora."; return 0; }
  return 1
}

case ${1:-} in
diagnosticar)
  command -v lpstat >/dev/null || { echo "Este equipo no tiene el sistema de impresión (CUPS) instalado."; exit 1; }
  m=$(no_puedo) && { echo "$m"; exit 3; }
  [ -n "$(impresoras)" ] || { echo "Este equipo no tiene impresoras instaladas; soporte tiene que instalarla."; exit 1; }
  e=$(elegida)
  [ -n "$e" ] || { echo "No encontré la impresora «${pedida}». Las instaladas son: $(impresoras | head -8 | paste -sd, - | sed 's/,/, /g')."; exit 1; }
  a=$(actual)
  if [ "$a" = "$e" ] && fija; then echo "«${e}» ya es la impresora predeterminada."; exit 10; fi
  if [ "$a" = "$e" ]; then echo "«${e}» ya es la predeterminada, pero macOS la cambia sola por la última que usaste; eso lo apago para que se quede."; exit 0; fi
  if [ -n "$a" ]; then echo "La predeterminada ahora es «${a}»; la cambio por «${e}»."; else echo "No tienes impresora predeterminada; dejo «${e}»."; fi
  exit 0 ;;
comprobar)
  m=$(no_puedo) && { echo "$m"; exit 3; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para cambiar la impresora predeterminada."; exit 3; }
  [ -n "$(elegida)" ] || { echo "No encontré la impresora «${pedida}»."; exit 3; }
  exit 0 ;;
aplicar)
  m=$(no_puedo) && { echo "$m"; exit 1; }
  e=$(elegida)
  [ -n "$e" ] || { echo "No encontré la impresora «${pedida}»."; exit 1; }
  lpadmin -d "$e" 2>/dev/null || { echo "No pude dejar «${e}» como predeterminada."; exit 1; }
  como lpoptions -d "$e" >/dev/null 2>&1
  como defaults write org.cups.PrintingPrefs UseLastPrinter -bool false 2>/dev/null
  echo "Dejé «${e}» como impresora predeterminada."
  exit 0 ;;
verificar)
  m=$(no_puedo) && { echo "$m"; exit 1; }
  e=$(elegida)
  { [ -n "$e" ] && [ "$(actual)" = "$e" ] && fija; } || { echo "La predeterminada no cambió."; exit 1; }
  echo "«${e}» es ahora la impresora predeterminada. Si tu programa recuerda otra, elígela una vez al imprimir; los programas que ya estaban abiertos la ven al volver a abrirlos."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
