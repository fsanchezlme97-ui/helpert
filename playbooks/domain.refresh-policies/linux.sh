#!/bin/bash
# Volver a aplicar las políticas del dominio en Linux, con la herramienta que tenga el equipo: ADSys (Ubuntu:
# equipo y cuentas con sesión) o samba-gpupdate (solo las del equipo). Sin ninguna de las dos, no hay políticas que
# aplicar aquí: lo dice y no hace nada.
set -u
herramienta() { if command -v adsysctl >/dev/null; then echo adsys; elif command -v samba-gpupdate >/dev/null; then echo samba; fi; }
dominio() { command -v realm >/dev/null && realm list --name-only 2>/dev/null | head -1; }

case ${1:-} in
diagnosticar)
  d=$(dominio); h=$(herramienta)
  [ -z "$d" ] && [ -z "$h" ] && { echo "Este equipo no está unido a un dominio de la empresa, así que no recibe políticas de dominio."; exit 3; }
  [ -z "$h" ] && { echo "El equipo está unido al dominio $d, pero no tiene una herramienta para aplicar sus políticas (ADSys o samba-gpupdate). Si falta una configuración, avisa a soporte."; exit 3; }
  echo "El equipo ${d:+está unido al dominio $d y }aplica sus políticas con $([ "$h" = adsys ] && echo ADSys || echo samba-gpupdate)."
  [ "$h" = adsys ] && echo "Puedo volver a aplicarlas ahora, las del equipo y las de las cuentas con sesión abierta." || echo "Puedo volver a aplicar ahora las políticas del equipo."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para aplicar las políticas."; exit 3; }
  [ -n "$(herramienta)" ] || { echo "Este equipo no tiene una herramienta para aplicar las políticas del dominio."; exit 3; }
  exit 0 ;;
aplicar)
  case $(herramienta) in
  adsys) timeout 250 adsysctl policy update --all >/dev/null 2>&1 ;;
  samba) timeout 250 samba-gpupdate --force >/dev/null 2>&1 ;;
  esac || { echo "No se pudieron aplicar las políticas; puede que el equipo no llegue a los servidores de la empresa (conéctate a la red de la oficina o a la VPN)."; exit 1; }
  echo "Volví a aplicar las políticas del dominio. Si una unidad o impresora no aparece todavía, cierra sesión y vuelve a entrar."
  exit 0 ;;
verificar)
  case $(herramienta) in
  adsys) [ -n "${HP_USUARIO:-}" ] && adsysctl policy applied "$HP_USUARIO" >/dev/null 2>&1 ;;  # incluye las del equipo
  samba) samba-gpupdate --rsop >/dev/null 2>&1 ;;
  *) false ;;
  esac || { echo "No pude confirmar que las políticas quedaron aplicadas. Avisa a soporte."; exit 1; }
  echo "Las políticas del dominio están aplicadas."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
