#!/bin/bash
# Reparar las fuentes: borra y reconstruye la caché de fontconfig (fc-cache -r) del sistema y, con el usuario de la
# persona, la suya (~/.cache/fontconfig, que incluye las fuentes que instaló ella en ~/.local/share/fonts).
set -u
usuario=${HP_USUARIO:-}
casa=; [ -n "$usuario" ] && [ "$usuario" != root ] && casa=$(getent passwd "$usuario" | cut -d: -f6)
fuentes() { fc-list 2>/dev/null | grep -c .; }

case ${1:-} in
diagnosticar)
  command -v fc-cache >/dev/null || { echo "Este equipo no tiene las herramientas de fuentes (fontconfig); no puedo reconstruir su caché."; exit 1; }
  echo "Hay $(fuentes) fuente(s) instaladas."
  echo "Puedo borrar y reconstruir la caché de fuentes para que los programas vuelvan a verlas bien; tarda menos de un minuto."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reconstruir la caché de fuentes."; exit 3; }
  command -v fc-cache >/dev/null || { echo "Este equipo no tiene las herramientas de fuentes (fontconfig)."; exit 3; }
  exit 0 ;;
aplicar)
  fc-cache -r -s >/dev/null 2>&1 || { echo "No pude reconstruir la caché de fuentes del sistema."; exit 1; }
  if [ -n "$casa" ] && [ -d "$casa" ]; then
    # con su usuario y su HOME: su caché y sus fuentes, nunca como root
    runuser -u "$usuario" -- env HOME="$casa" fc-cache -r >/dev/null 2>&1 && tuya=si || tuya=no
  else tuya=no; fi
  echo "Reconstruí la caché de fuentes del sistema."
  [ "$tuya" = si ] && echo "También reconstruí la tuya, con tus fuentes."
  [ "$tuya" = no ] && echo "No pude reconstruir tu caché de fuentes personal: se rehace sola al abrir los programas."
  echo "Cierra y vuelve a abrir los programas para que vean las fuentes; si alguno sigue igual, cierra sesión y vuelve a entrar."
  exit 0 ;;
verificar)
  n=$(fuentes)
  [ "$n" -gt 0 ] || { echo "El sistema no encuentra ninguna fuente después de reconstruir la caché."; exit 1; }
  echo "La caché de fuentes está bien: el sistema ve $n fuente(s)."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
