#!/bin/bash
# Borrar la caché de miniaturas de Quick Look y la de iconos de la persona (en su carpeta de cachés, la que da
# «getconf DARWIN_USER_CACHE_DIR»); se rehacen solas. Con sus permisos (sudo -u): find -delete no sigue enlaces.
# No se reinicia el Dock ni el Finder (son del escritorio): si algún icono sigue mal, basta cerrar sesión.
set -u
usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los archivos de otra persona."; return 1; }
  c=$(como getconf DARWIN_USER_CACHE_DIR 2>/dev/null)
  case $c in /var/folders/?*|/private/var/folders/?*) ;; *) echo "No encontré tu carpeta de cachés."; return 1 ;; esac
}
archivos() {
  for d in com.apple.QuickLook.thumbnailcache com.apple.iconservices; do
    [ -d "$c/$d" ] && como find "$c/$d" -type f "$@" 2>/dev/null
  done
}
mb() { archivos -size +0 -exec stat -f '%z' {} + | awk '{ s += $1 } END { printf "%d", s / 1048576 }'; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  n=$(archivos | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 0 ] || { echo "No encontré caché de iconos ni de miniaturas en tu cuenta: no hay nada que borrar."; echo "Si los iconos siguen en blanco, cierra sesión y vuelve a entrar."; exit 10; }
  echo "Tu caché de iconos y miniaturas tiene $n archivo(s) y ocupa $(mb) MB."
  echo "Si sigo, la borro; se rehace sola la próxima vez que abras las carpetas (las primeras veces pueden tardar un poco)."
  exit 0 ;;
comprobar)
  puedo || exit 3
  exit 0 ;;
aplicar)
  puedo || exit 1
  m=$(mb)
  archivos -delete
  # que Quick Look olvide lo que tenía en memoria; en su sesión gráfica si la hay
  launchctl asuser "$uid" sudo -u "$usuario" qlmanage -r cache >/dev/null 2>&1 || como qlmanage -r cache >/dev/null 2>&1
  [ "$(archivos -mmin +10 | wc -l | tr -d ' ')" -eq 0 ] || { echo "No pude borrar parte de la caché."; exit 1; }
  echo "Borré la caché de iconos y miniaturas ($m MB). Abre de nuevo la carpeta: se rehace sola."
  exit 0 ;;
verificar)
  puedo || exit 1
  n=$(archivos -mmin +10 | wc -l | tr -d ' ')
  [ "${n:-0}" -eq 0 ] || { echo "Quedan $n archivo(s) de la caché antigua."; exit 1; }
  echo "La caché antigua ya no está. Si algún icono sigue en blanco, cierra sesión y vuelve a entrar."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
