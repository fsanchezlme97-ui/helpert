#!/bin/bash
# Restablecer LibreOffice: renombra el perfil de la persona (~/.config/libreoffice/4, también Flatpak y Snap) a
# 4.helpert-<fecha> para que LibreOffice cree uno nuevo. Deshacer devuelve el más reciente a su lugar. Los documentos
# no se tocan. Solo con LibreOffice cerrado; todo con el usuario de la persona, nunca como root.
set -u
PROC='soffice\.bin|soffice|oosplash'
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && getent passwd "$usuario" | cut -d: -f6)
# carpetas donde vive el perfil «4»
PADRES=("$casa/.config/libreoffice" "$casa/.var/app/org.libreoffice.LibreOffice/config/libreoffice" "$casa/snap/libreoffice/current/.config/libreoffice")

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los programas de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
abierto() { pgrep -u "$usuario" -x "$PROC" >/dev/null; }
perfiles() { for p in "${PADRES[@]}"; do como test -d "$p/4" && echo "$p/4"; done; }
# respaldo más reciente de una carpeta padre (los nombres llevan la fecha, así que se ordenan solos)
respaldo() { como find "$1" -mindepth 1 -maxdepth 1 -type d -name '4.helpert-[0-9]*' 2>/dev/null | sort | tail -1; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  mapfile -t lista < <(perfiles)
  [ ${#lista[@]} -gt 0 ] || { echo "No encontré un perfil de LibreOffice en tu carpeta: se crea solo la primera vez que lo abres."; exit 10; }
  echo "Encontré tu perfil de LibreOffice. Lo renombraría para que empiece con uno nuevo; tus documentos no se tocan."
  echo "Tus ajustes, diccionario personal y macros quedan guardados en el perfil viejo y se pueden recuperar deshaciendo."
  abierto && echo "LibreOffice está abierto: ciérralo (también el inicio rápido) antes de que lo restablezca."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(perfiles)" ] || { echo "No hay perfil de LibreOffice que restablecer."; exit 3; }
  abierto && { echo "LibreOffice está abierto: guarda tus documentos, ciérralo y vuelve a pedírmelo."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  abierto && { echo "LibreOffice está abierto: no toqué nada."; exit 1; }
  fecha=$(date +%Y%m%d-%H%M%S)
  mapfile -t lista < <(perfiles)
  for p in "${lista[@]}"; do
    como mv -T -- "$p" "$p.helpert-$fecha" || { echo "No pude renombrar tu perfil de LibreOffice."; exit 1; }
  done
  echo "Renombré tu perfil de LibreOffice. Ábrelo: empezará con la configuración inicial. Si quieres volver al anterior, se puede deshacer."
  exit 0 ;;
verificar)
  puedo || exit 1
  abierto && { echo "LibreOffice ya está abierto con un perfil nuevo."; exit 0; }
  [ -z "$(perfiles)" ] || { echo "El perfil viejo de LibreOffice sigue en su lugar."; exit 1; }
  echo "Listo: LibreOffice creará un perfil nuevo al abrirlo."
  exit 0 ;;
deshacer)
  puedo || exit 1
  abierto && { echo "LibreOffice está abierto: ciérralo y vuelve a pedírmelo."; exit 1; }
  fecha=$(date +%Y%m%d-%H%M%S) n=0
  for p in "${PADRES[@]}"; do
    r=$(respaldo "$p"); [ -n "$r" ] || continue
    # el perfil nuevo que se haya creado queda a un lado, por si acaso
    if como test -e "$p/4"; then como mv -T -- "$p/4" "$p/4.helpert-nuevo-$fecha" || { echo "No pude apartar el perfil nuevo."; exit 1; }; fi
    como mv -T -- "$r" "$p/4" || { echo "No pude devolver tu perfil anterior de LibreOffice."; exit 1; }
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "No encontré un perfil anterior de LibreOffice que devolver."; exit 1; }
  echo "Devolví tu perfil anterior de LibreOffice, con tus ajustes de antes."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
