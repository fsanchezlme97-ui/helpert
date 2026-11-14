#!/bin/bash
# Revisar el lector de huellas: si el servicio de huellas (fprintd) ve un lector y reiniciarlo. No registra huellas:
# solo dice si la persona no tiene ninguna registrada.
set -u
usuario=${HP_USUARIO:-}
servicio() { command -v systemctl >/dev/null && systemctl cat fprintd.service >/dev/null 2>&1; }
# cuántos lectores ve fprintd (lo arranca D-Bus si hace falta)
lectores() {
  command -v busctl >/dev/null || { echo 0; return; }
  n=$(timeout 15 busctl call net.reactivated.Fprint /net/reactivated/Fprint/Manager net.reactivated.Fprint.Manager GetDevices 2>/dev/null | awk '{print $2 + 0}')
  echo "${n:-0}"
}
# un sensor de huellas conectado por USB (por fabricante), aunque fprintd no lo reconozca
sensor() {
  for d in /sys/bus/usb/devices/*; do
    case $(cat "$d/idVendor" 2>/dev/null) in 06cb|27c6|138a|1c7a|10a5|08ff|147e|2808|298d) return 0 ;; esac
  done
  return 1
}
sin_huellas() {
  [ -n "$usuario" ] && [ "$usuario" != root ] && command -v fprintd-list >/dev/null || return 1
  timeout 15 fprintd-list "$usuario" 2>/dev/null | grep -q 'no fingers enrolled'
}

case ${1:-} in
diagnosticar)
  servicio || { echo "Este equipo no tiene el servicio de huellas (fprintd): pide a soporte que lo instale."; exit 1; }
  if [ "$(lectores)" -gt 0 ]; then
    echo "El equipo detecta el lector de huellas."
    sin_huellas && echo "No tienes ninguna huella registrada: regístrala en la configuración de usuarios del escritorio (Helpert no registra huellas)."
    echo "Voy a reiniciar el servicio de huellas."
    exit 0
  fi
  if sensor; then
    echo "El equipo tiene un lector de huellas, pero el servicio de huellas no lo reconoce."
    echo "Voy a reiniciar el servicio; si sigue igual, puede que ese lector no tenga controlador para Linux: eso lo revisa soporte."
    exit 0
  fi
  echo "El equipo no detecta ningún lector de huellas. Si es externo, desconéctalo, espera 5 segundos y conéctalo en otro puerto."
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el servicio de huellas."; exit 3; }
  servicio || { echo "Este equipo no tiene el servicio de huellas (fprintd)."; exit 3; }
  exit 0 ;;
aplicar)
  systemctl restart fprintd.service 2>/dev/null || { echo "No pude reiniciar el servicio de huellas."; exit 1; }
  sleep 2
  echo "Reinicié el servicio de huellas."
  exit 0 ;;
verificar)
  [ "$(lectores)" -gt 0 ] || { echo "El servicio de huellas sigue sin reconocer el lector: avisa a soporte para que revise su controlador."; exit 1; }
  echo "El lector de huellas funciona. Bloquea la sesión y prueba entrar con tu huella."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
