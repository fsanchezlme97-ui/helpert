#!/bin/bash
# Activar el cortafuegos (firewalld o ufw, el que tenga el equipo) con su configuración por defecto.
# No borra ni agrega reglas: abrir puertos lo hace soporte. Si soporte lo bloqueó a propósito (masked), no lo toca.
set -u
herramienta() {
  if systemctl cat firewalld.service >/dev/null 2>&1; then echo firewalld
  elif command -v ufw >/dev/null; then echo ufw; fi
}
activo() {
  case $(herramienta) in
  firewalld) systemctl is-active -q firewalld 2>/dev/null ;;
  ufw) ufw status 2>/dev/null | grep -q '^Status: active' ;;
  *) return 1 ;;
  esac
}
bloqueado() { [ "$(herramienta)" = firewalld ] && [ "$(systemctl is-enabled firewalld 2>/dev/null)" = masked ]; }

case ${1:-} in
diagnosticar)
  h=$(herramienta)
  [ -n "$h" ] || { echo "Este equipo no tiene un cortafuegos instalado (firewalld o ufw). Pide a soporte que lo instale."; exit 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para revisar el cortafuegos."; exit 3; }
  activo && { echo "El cortafuegos ($h) está activo. No hay nada que hacer."; exit 10; }
  bloqueado && { echo "El cortafuegos ($h) está apagado y bloqueado a propósito en este equipo: pide a soporte que lo revise."; exit 3; }
  echo "El cortafuegos ($h) está apagado."
  echo "Lo puedo activar con su configuración por defecto, sin borrar reglas ni abrir puertos."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para activar el cortafuegos."; exit 3; }
  [ -n "$(herramienta)" ] || { echo "Este equipo no tiene un cortafuegos instalado (firewalld o ufw)."; exit 3; }
  bloqueado && { echo "El cortafuegos está bloqueado a propósito en este equipo: lo decide soporte."; exit 3; }
  exit 0 ;;
aplicar)
  h=$(herramienta)
  case $h in
  firewalld) systemctl enable --now firewalld >/dev/null 2>&1 ;;
  ufw) ufw --force enable >/dev/null 2>&1 ;;
  esac || { echo "No se pudo activar el cortafuegos ($h)."; exit 1; }
  echo "Activé el cortafuegos ($h) con su configuración por defecto."
  exit 0 ;;
verificar)
  for _ in 1 2 3 4 5; do activo && break; sleep 1; done
  activo || { echo "El cortafuegos sigue apagado."; exit 1; }
  echo "El cortafuegos está activo y protege el equipo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
