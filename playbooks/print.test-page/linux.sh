#!/bin/bash
# Imprimir una página de prueba (CUPS). HP_IMPRESORA (opcional, ya validado) se busca sin distinguir mayúsculas; sin
# él, la predeterminada de la persona (leída como ella: puede tener la suya en ~/.cups/lpoptions) o la del equipo.
# No envía a impresoras virtuales (PDF, archivo, fax): ahí no sale papel y el trabajo puede quedarse esperando.
set -u
usuario=${HP_USUARIO:-}
pedida=${HP_IMPRESORA:-}
VIRTUAL='pdf|xps|fax|onenote'

impresoras() { lpstat -e 2>/dev/null; }
activo() { lpstat -r 2>/dev/null | grep -q 'is running'; }
predeterminada() {
  d=""
  if [ "$(id -u)" -eq 0 ] && [ -n "$usuario" ] && [ "$usuario" != root ] && id -u "$usuario" >/dev/null 2>&1; then
    d=$(runuser -u "$usuario" -- lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
  fi
  [ -n "$d" ] || d=$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
  echo "$d"
}
destino() {
  [ -n "$pedida" ] || { predeterminada; return; }
  e=$(impresoras | grep -ixF -- "$pedida" | head -1)
  [ -n "$e" ] || e=$(impresoras | grep -iF -- "$pedida" | head -1)
  echo "$e"
}
virtual() { echo "$1" | grep -Eiq "$VIRTUAL" || lpstat -v "$1" 2>/dev/null | grep -Eq ': (cups-pdf|file|pdf):'; }
pausada() { lpstat -p "$1" 2>/dev/null | grep -q 'disabled' || lpstat -a "$1" 2>/dev/null | grep -q 'not accepting'; }
pendientes() { lpstat -o "$1" 2>/dev/null | grep -c .; }
# el motivo por el que no se puede enviar la prueba (vacío si se puede)
motivo() {
  command -v lp >/dev/null || { echo "Este equipo no tiene el sistema de impresión (CUPS) instalado."; return; }
  activo || { echo "El servicio de impresión está detenido: usa primero «Liberar cola de impresión»."; return; }
  [ -n "$(impresoras)" ] || { echo "Este equipo no tiene impresoras instaladas; soporte tiene que instalarla."; return; }
  p=$(destino)
  if [ -z "$p" ] && [ -n "$pedida" ]; then echo "No encontré la impresora «$pedida». Las instaladas son: $(impresoras | head -8 | paste -sd, - | sed 's/,/, /g')."; return; fi
  [ -n "$p" ] || { echo "No hay una impresora predeterminada: dime a qué impresora envío la prueba."; return; }
  virtual "$p" && { echo "«$p» no es una impresora de papel (guarda en un archivo): dime una impresora de verdad."; return; }
  pausada "$p" && echo "La impresora «$p» está en pausa: usa primero «Liberar cola de impresión» para reactivarla."
}

case ${1:-} in
diagnosticar)
  m=$(motivo); [ -z "$m" ] || { echo "$m"; exit 1; }
  p=$(destino); n=$(pendientes "$p")
  echo "Voy a enviar una página de prueba a «$p»."
  [ "${n:-0}" -gt 0 ] && echo "Tiene $n trabajo(s) esperando en la cola: la prueba saldrá después de ellos."
  exit 0 ;;
comprobar)
  m=$(motivo); [ -z "$m" ] || { echo "$m"; exit 3; }
  exit 0 ;;
aplicar)
  p=$(destino)
  [ -n "$p" ] || { echo "No sé a qué impresora enviar la prueba."; exit 1; }
  hoja=/usr/share/cups/data/testprint tmp=""
  if [ ! -r "$hoja" ]; then
    tmp=$(mktemp) || { echo "No pude preparar la página de prueba."; exit 1; }
    printf 'Página de prueba de Helpert\n\nImpresora: %s\nEquipo: %s\nFecha: %s\n\nSi puedes leer esto, la impresora funciona.\n' \
      "$p" "$(uname -n)" "$(date '+%d/%m/%Y %H:%M')" > "$tmp"
    hoja=$tmp
  fi
  lp -d "$p" -t "Página de prueba de Helpert" "$hoja" >/dev/null 2>&1; r=$?
  [ -z "$tmp" ] || rm -f "$tmp"
  [ "$r" -eq 0 ] || { echo "No pude enviar la página de prueba a «$p»."; exit 1; }
  echo "Envié una página de prueba a «$p»."
  exit 0 ;;
verificar)
  p=$(destino)
  [ -n "$p" ] || { echo "No sé a qué impresora envié la prueba."; exit 1; }
  i=0; while [ "$i" -lt 20 ] && [ "$(pendientes "$p")" -gt 0 ]; do sleep 1; i=$((i + 1)); done
  pausada "$p" && { echo "La impresora «$p» dio un error y quedó en pausa: revisa que esté encendida y conectada, y usa «Liberar cola de impresión»."; exit 1; }
  [ "$(pendientes "$p")" -eq 0 ] || { echo "La página sigue en la cola de «$p» sin imprimirse: la impresora no responde. Revisa que esté encendida, con papel y conectada."; exit 1; }
  echo "La página de prueba ya pasó a «$p»."
  echo "Si no salió el papel, revisa que esté encendida, con papel y sin luces de error; si sigue igual, avisa a soporte."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
