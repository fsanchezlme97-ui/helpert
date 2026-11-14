#!/bin/bash
# Borrar la caché de miniaturas (~/.cache/thumbnails, estándar freedesktop) y la de iconos de KDE
# (~/.cache/icon-cache.kcache) de la persona; se rehacen solas. Con sus permisos (runuser): find -delete no sigue enlaces.
# Las cachés de iconos de los temas son del sistema y no se tocan.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar los archivos de otra persona."; return 1; }
}
archivos() { como find "$casa/.cache/thumbnails" "$casa/.cache/icon-cache.kcache" -type f "$@" 2>/dev/null; }
mb() { archivos -printf '%s\n' | awk '{ s += $1 } END { printf "%d", s / 1048576 }'; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  n=$(archivos | wc -l)
  [ "$n" -gt 0 ] || { echo "No encontré caché de iconos ni de miniaturas en tu carpeta: no hay nada que borrar."; echo "Si los iconos siguen en blanco, cierra sesión y vuelve a entrar."; exit 10; }
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
  # las que queden de antes (más de 10 minutos) son las que no se pudieron borrar
  [ "$(archivos -mmin +10 | wc -l)" -eq 0 ] || { echo "No pude borrar parte de la caché."; exit 1; }
  echo "Borré la caché de iconos y miniaturas ($m MB). Abre de nuevo la carpeta: se rehace sola."
  exit 0 ;;
verificar)
  puedo || exit 1
  n=$(archivos -mmin +10 | wc -l)
  [ "$n" -eq 0 ] || { echo "Quedan $n archivo(s) de la caché antigua."; exit 1; }
  echo "La caché antigua ya no está. Si algún icono sigue en blanco, cierra sesión y vuelve a entrar."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
