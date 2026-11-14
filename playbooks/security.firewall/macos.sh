#!/bin/bash
# Activar el cortafuegos de macOS (Application Firewall) con su configuración por defecto: no borra reglas ni abre
# puertos. Si lo administra la empresa (perfil MDM), no lo toca.
set -u
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
activo() { "$FW" --getglobalstate 2>/dev/null | grep -q 'State = [12]'; }
gestionado() { [ -e "/Library/Managed Preferences/com.apple.security.firewall.plist" ]; }

case ${1:-} in
diagnosticar)
  [ -x "$FW" ] || { echo "No encuentro la herramienta del cortafuegos de macOS."; exit 1; }
  activo && { echo "El cortafuegos de macOS está activo. No hay nada que hacer."; exit 10; }
  gestionado && { echo "El cortafuegos está apagado y lo administra la empresa (perfil de gestión): pide a soporte que lo revise."; exit 3; }
  echo "El cortafuegos de macOS está apagado."
  echo "Lo puedo activar con su configuración por defecto, sin borrar reglas ni abrir puertos."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para activar el cortafuegos."; exit 3; }
  [ -x "$FW" ] || { echo "No encuentro la herramienta del cortafuegos de macOS."; exit 3; }
  gestionado && { echo "El cortafuegos lo administra la empresa (perfil de gestión): lo decide soporte."; exit 3; }
  exit 0 ;;
aplicar)
  "$FW" --setglobalstate on >/dev/null 2>&1 || { echo "No se pudo activar el cortafuegos."; exit 1; }
  echo "Activé el cortafuegos de macOS con su configuración por defecto."
  exit 0 ;;
verificar)
  activo || { echo "El cortafuegos sigue apagado."; exit 1; }
  echo "El cortafuegos de macOS está activo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
