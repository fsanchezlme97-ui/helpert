#!/bin/bash
# Revisar el escáner: si SANE lo detecta (scanimage -L) y reiniciar el servicio de escaneo. En Linux ese servicio es
# ipp-usb (escáneres USB sin controlador propio); si el equipo no lo tiene, no hay servicio que reiniciar.
# No instala controladores.
set -u
servicio() { command -v systemctl >/dev/null && systemctl cat ipp-usb.service >/dev/null 2>&1; }
# nombre de cada escáner que ve SANE («device `airscan:e0:HP' is a eSCL HP LaserJet» → «eSCL HP LaserJet»)
escaneres() { timeout 30 scanimage -L 2>/dev/null | sed -n 's/^device .* is a //p' | head -3; }
lista() { paste -sd, - | sed 's/,/, /g'; }

case ${1:-} in
diagnosticar)
  { command -v scanimage >/dev/null && command -v timeout >/dev/null; } || { echo "Este equipo no tiene instalado el sistema de escaneo (SANE): pide a soporte que lo instale."; exit 1; }
  e=$(escaneres)
  if [ -n "$e" ]; then echo "El equipo detecta el escáner: $(echo "$e" | lista)."
  else echo "El equipo no detecta ningún escáner."; fi
  if servicio; then echo "Voy a reiniciar el servicio de escaneo."; exit 0; fi
  if [ -n "$e" ]; then echo "Ábrelo desde la aplicación de escaneo y elige ese escáner; si da error, desconéctalo, espera 5 segundos y conéctalo."
  else echo "Si es USB, desconéctalo y conéctalo en otro puerto; si es de red, revisa que esté encendido y en la misma red. Si sigue sin aparecer, puede faltar su controlador: eso lo instala soporte."; fi
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el servicio de escaneo."; exit 3; }
  servicio || { echo "Este equipo no tiene un servicio de escaneo que se pueda reiniciar."; exit 3; }
  exit 0 ;;
aplicar)
  systemctl restart ipp-usb.service 2>/dev/null || { echo "No pude reiniciar el servicio de escaneo."; exit 1; }
  sleep 3
  echo "Reinicié el servicio de escaneo."
  exit 0 ;;
verificar)
  e=$(escaneres)
  [ -n "$e" ] || { echo "El escáner sigue sin aparecer. Revisa el cable o la red; si sigue igual, pide a soporte que revise su controlador."; exit 1; }
  echo "El equipo detecta el escáner: $(echo "$e" | lista). Prueba escanear de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
