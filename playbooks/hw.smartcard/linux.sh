#!/bin/bash
# Revisar el lector de tarjetas o DNIe: si el equipo ve un lector USB de tarjetas inteligentes (clase CCID, 0x0b) y
# reiniciar el servicio de tarjetas (pcscd). No instala controladores ni toca certificados.
set -u
servicio() { command -v systemctl >/dev/null && { systemctl cat pcscd.service >/dev/null 2>&1 || systemctl cat pcscd.socket >/dev/null 2>&1; }; }
lectores() {
  for i in /sys/bus/usb/devices/*:*; do
    [ "$(cat "$i/bInterfaceClass" 2>/dev/null)" = 0b ] || continue
    n=$(cat "${i%:*}/product" 2>/dev/null); echo "${n:-lector de tarjetas USB}"
  done | sort -u | head -3 | paste -sd, - | sed 's/,/, /g'
}
activo() { systemctl is-active --quiet pcscd.service 2>/dev/null || systemctl is-active --quiet pcscd.socket 2>/dev/null; }

case ${1:-} in
diagnosticar)
  servicio || { echo "Este equipo no tiene el servicio de tarjetas inteligentes (pcscd): pide a soporte que lo instale."; exit 1; }
  l=$(lectores)
  if [ -z "$l" ]; then
    echo "El equipo no detecta ningún lector de tarjetas."
    echo "Desconecta el lector o el token, espera 5 segundos y conéctalo en otro puerto. Si el lector es del teclado o de la laptop, reinicia el equipo."
    exit 10
  fi
  echo "El equipo detecta el lector: $l."
  command -v opensc-tool >/dev/null || echo "No veo OpenSC, que usan el DNIe y muchas tarjetas: si tu tarjeta sigue sin funcionar, pide a soporte que lo instale."
  echo "Voy a reiniciar el servicio de tarjetas. Cierra antes el navegador o el programa de firma que la estaba usando."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el servicio de tarjetas."; exit 3; }
  servicio || { echo "Este equipo no tiene el servicio de tarjetas inteligentes (pcscd)."; exit 3; }
  exit 0 ;;
aplicar)
  systemctl restart pcscd.service 2>/dev/null || systemctl restart pcscd.socket 2>/dev/null || { echo "No pude reiniciar el servicio de tarjetas."; exit 1; }
  sleep 2
  echo "Reinicié el servicio de tarjetas."
  exit 0 ;;
verificar)
  activo || { echo "El servicio de tarjetas no volvió a arrancar: avisa a soporte."; exit 1; }
  l=$(lectores)
  [ -n "$l" ] || { echo "El servicio funciona, pero el equipo ya no detecta el lector: desconéctalo y conéctalo en otro puerto."; exit 1; }
  echo "El servicio de tarjetas funciona y detecta el lector: $l. Saca la tarjeta, vuelve a ponerla y abre de nuevo el programa de firma o el navegador."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
