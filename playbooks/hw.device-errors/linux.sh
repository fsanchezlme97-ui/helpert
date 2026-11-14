#!/bin/bash
# Revisar dispositivos con errores: los USB que el kernel no pudo reconocer (su registro de la última hora) y volver
# a detectar: reenvía los avisos de USB a udev, que carga los controladores que falten. No reinicia ni desconecta ningún dispositivo (un disco a medio escribir o la red se cortarían).
set -u
ERR='device descriptor read|device not accepting address|unable to enumerate USB device|Cannot enable\. Maybe the USB cable is bad|can.t set config|over-current'

# «puerto veces» de los USB con error desde $1 (p. ej. -60min); «usb 1-2: …» y «usb usb1-port2: …» son el puerto 1-2
fallos() {
  { journalctl -k -q --no-pager -o cat --since "$1" 2>/dev/null || dmesg 2>/dev/null; } | grep -E "$ERR" |
    grep -oE 'usb[0-9]+-port[0-9.]+|usb [0-9]+-[0-9.]+' | sed -E 's/^usb([0-9]+)-port/\1-/; s/^usb //' | sort | uniq -c | awk '{print $2, $1}'
}

case ${1:-} in
diagnosticar)
  command -v udevadm >/dev/null || { echo "Este equipo no tiene udev: no puedo revisar los dispositivos."; exit 1; }
  f=$(fallos -60min)
  if [ -z "$f" ]; then
    echo "No encontré dispositivos con errores en la última hora."
    echo "Si uno no funciona, desconéctalo, espera 5 segundos y conéctalo en otro puerto; si es interno, reinicia el equipo."
    exit 10
  fi
  echo "En la última hora, $(echo "$f" | wc -l) dispositivo(s) USB no se pudieron reconocer:"
  echo "$f" | head -5 | while read -r p v; do echo "- Uno conectado en el puerto USB $p ($v intento(s) fallido(s))."; done
  echo "Voy a pedirle al sistema que vuelva a detectar los dispositivos."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para volver a detectar los dispositivos."; exit 3; }
  command -v udevadm >/dev/null || { echo "Este equipo no tiene udev para volver a detectar los dispositivos."; exit 3; }
  exit 0 ;;
aplicar)
  udevadm trigger --action=add --subsystem-match=usb 2>/dev/null || { echo "No pude volver a detectar los dispositivos."; exit 1; }
  udevadm settle --timeout=30 2>/dev/null
  echo "Le pedí al sistema que vuelva a detectar los dispositivos."
  exit 0 ;;
verificar)
  f=$(fallos -2min)
  [ -z "$f" ] || { echo "Un dispositivo USB sigue sin poder reconocerse: conéctalo en otro puerto o con otro cable; si sigue igual, puede estar dañado y lo revisa soporte."; exit 1; }
  echo "No hay errores nuevos. Si el dispositivo sigue sin funcionar, desconéctalo y conéctalo en otro puerto; si es interno, reinicia el equipo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
