#!/bin/bash
# Revisar los dispositivos USB: lista lo que el equipo detecta por USB (sin los concentradores) y reinicia la
# detección: reenvía los avisos de USB a udev, que carga los controladores que falten. No reinicia ni desconecta
# ningún dispositivo (una memoria a medio escribir se dañaría).
set -u
USB=/sys/bus/usb/devices
ERR='device descriptor read|device not accepting address|unable to enumerate USB device|Cannot enable\. Maybe the USB cable is bad|can.t set config|over-current'

dispositivos() {
  for d in "$USB"/*; do
    [ -r "$d/idVendor" ] || continue
    [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = 09 ] && continue  # concentrador
    n=$(cat "$d/product" 2>/dev/null); m=$(cat "$d/manufacturer" 2>/dev/null)
    [ -n "$n" ] || n="dispositivo sin nombre ($(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null))"
    echo "$n${m:+ ($m)}"
  done | sort -u
}
# cuántos avisos de USB que no se pudieron reconocer dejó el kernel desde $1 (p. ej. -60min)
fallos() { { journalctl -k -q --no-pager -o cat --since "$1" 2>/dev/null || dmesg 2>/dev/null; } | grep -cE "$ERR"; }
resumen() {
  l=$(dispositivos); n=$(echo "$l" | grep -c .)
  [ "$n" -gt 0 ] || { echo "El equipo no detecta ningún dispositivo USB conectado."; return; }
  echo "El equipo detecta $n dispositivo(s) USB:"
  echo "$l" | grep . | head -6 | sed 's/^/- /'
  [ "$n" -gt 6 ] && echo "… y $((n - 6)) más."
}

case ${1:-} in
diagnosticar)
  [ -d "$USB" ] || { echo "Este equipo no tiene USB que pueda revisar."; exit 3; }
  resumen
  [ "$(fallos -60min)" -gt 0 ] && echo "En la última hora, un dispositivo USB no se pudo reconocer: puede ser el cable, el puerto o el propio dispositivo."
  echo "Voy a reiniciar la detección de USB. Si lo que falla es una memoria, usa «Abrir una memoria USB»."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar la detección de USB."; exit 3; }
  command -v udevadm >/dev/null || { echo "Este equipo no tiene udev para reiniciar la detección de USB."; exit 3; }
  exit 0 ;;
aplicar)
  udevadm trigger --action=add --subsystem-match=usb 2>/dev/null || { echo "No pude reiniciar la detección de USB."; exit 1; }
  udevadm settle --timeout=30 2>/dev/null
  echo "Reinicié la detección de USB."
  exit 0 ;;
verificar)
  [ "$(fallos -2min)" -eq 0 ] || { echo "Un dispositivo USB sigue sin poder reconocerse: conéctalo en otro puerto o con otro cable; si sigue igual, puede estar dañado."; exit 1; }
  resumen
  echo "Si el tuyo no aparece, desconéctalo, espera 5 segundos y conéctalo en otro puerto."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
