#!/bin/bash
# Poner el perfil de energía equilibrado (power-profiles-daemon, o tuned-ppd en Fedora: la misma interfaz por D-Bus).
set -u
# nombre nuevo del servicio y el de siempre (los dos los atiende el mismo daemon)
SERVICIOS=("org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles"
           "net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles")
# $s va sin comillas a propósito: son las tres palabras (servicio, ruta, interfaz)
perfil() {  # perfil activo (balanced, power-saver, performance); nada si no hay servicio de perfiles
  for s in "${SERVICIOS[@]}"; do
    p=$(busctl get-property $s ActiveProfile 2>/dev/null | awk '{gsub(/"/, "", $2); print $2}')
    [ -n "$p" ] && { echo "$p"; return; }
  done
}
poner() { for s in "${SERVICIOS[@]}"; do busctl set-property $s ActiveProfile s balanced 2>/dev/null && return 0; done; return 1; }
nombre() { case $1 in power-saver) echo "ahorro de energía" ;; performance) echo "alto rendimiento" ;; *) echo "$1" ;; esac; }

case ${1:-} in
diagnosticar)
  command -v busctl >/dev/null || { echo "No puedo revisar el plan de energía en este equipo."; exit 1; }
  p=$(perfil)
  [ -n "$p" ] || { echo "Este equipo no tiene perfiles de energía que se puedan cambiar (no tiene el servicio de perfiles de energía)."; exit 3; }
  [ "$p" = balanced ] && { echo "El plan de energía ya está en equilibrado."; exit 10; }
  echo "El plan de energía está en «$(nombre "$p")». Lo dejaría en equilibrado."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para cambiar el plan de energía."; exit 3; }
  [ -n "$(perfil)" ] || { echo "El servicio de perfiles de energía no responde."; exit 3; }
  exit 0 ;;
aplicar)
  poner || { echo "No se pudo cambiar el plan de energía."; exit 1; }
  echo "Dejé el plan de energía en equilibrado."
  exit 0 ;;
verificar)
  p=$(perfil)
  [ "$p" = balanced ] || { echo "El plan de energía sigue en «$(nombre "${p:-desconocido}")»."; exit 1; }
  echo "El plan de energía está en equilibrado."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
