#!/bin/bash
# Reparar las fuentes del Mac: borra las cachés de fuentes del sistema (atsutil databases -remove) y, con el usuario
# de la persona, las suyas (-removeUser); macOS las rehace solo. Luego reinicia el servidor de fuentes.
set -u
usuario=${HP_USUARIO:-}

case ${1:-} in
diagnosticar)
  command -v atsutil >/dev/null || { echo "Esta versión de macOS no tiene la herramienta de caché de fuentes (atsutil); no puedo reconstruirla."; exit 1; }
  echo "Puedo borrar la caché de fuentes para que macOS la reconstruya y los programas vuelvan a ver bien las fuentes."
  echo "Después conviene cerrar sesión o reiniciar el equipo."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reconstruir la caché de fuentes."; exit 3; }
  command -v atsutil >/dev/null || { echo "Esta versión de macOS no tiene la herramienta de caché de fuentes (atsutil)."; exit 3; }
  exit 0 ;;
aplicar)
  atsutil databases -remove >/dev/null 2>&1 || { echo "No pude borrar la caché de fuentes del sistema."; exit 1; }
  tuya=no
  if [ -n "$usuario" ] && [ "$usuario" != root ] && id -u "$usuario" >/dev/null 2>&1; then
    sudo -n -u "$usuario" atsutil databases -removeUser >/dev/null 2>&1 && tuya=si
  fi
  atsutil server -shutdown >/dev/null 2>&1
  atsutil server -ping >/dev/null 2>&1
  echo "Borré la caché de fuentes del sistema; macOS la está reconstruyendo."
  [ "$tuya" = si ] && echo "También borré la tuya."
  [ "$tuya" = no ] && echo "No pude borrar tu caché de fuentes personal."
  echo "Cierra sesión y vuelve a entrar (o reinicia el equipo) para que todos los programas usen la caché nueva."
  exit 0 ;;
verificar)
  atsutil server -ping >/dev/null 2>&1 || { echo "El servidor de fuentes de macOS no responde."; exit 1; }
  echo "El servidor de fuentes funciona y la caché se está reconstruyendo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
