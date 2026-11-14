#!/bin/bash
# Devolver a la persona la propiedad de los archivos de su carpeta personal que quedaron a nombre de otra cuenta
# (típico tras usar sudo). Cambiar el dueño necesita root, así que aquí no se puede actuar como la persona; por eso:
# - solo cuentas de personas (UID 1000 o más) con la carpeta en /home o /var/home;
# - sin cruzar a otros discos (-xdev) ni tocar la raíz de un disco montado dentro, ni entrar en los contenedores sin root
#   (usan cuentas propias a propósito);
# - solo si el sistema no deja enlazar archivos ajenos (fs.protected_hardlinks = 1): si no, la persona podría cambiar un
#   archivo por un enlace a uno del sistema justo antes del chown;
# - chown -h (un enlace no lleva a otro archivo) desde -execdir (un cambio de carpeta en medio no lleva fuera);
# - archivos con un solo enlace duro: uno del sistema enlazado dentro de su carpeta no pasa a ser suyo.
# Solo cambia el dueño: el grupo y los permisos quedan igual.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
uid=$(id -u "$usuario" 2>/dev/null)

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ] && [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide, o su cuenta no es de una persona."; return 1; }
  local ok=0
  case $casa in
  */../*|*/..) ;;  # con «..» podría salir de /home
  /home/?*|/var/home/?*) ok=1 ;;
  esac
  [ "$ok" = 1 ] || { echo "Tu carpeta personal ($casa) no está donde suelen estar: no la toco. Pide a soporte que la revise."; return 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para cambiar a quién pertenecen los archivos."; return 1; }
  [ "$(cat /proc/sys/fs/protected_hardlinks 2>/dev/null)" = 1 ] || { echo "Este equipo no tiene activada una protección del sistema (fs.protected_hardlinks) y no es seguro cambiar el dueño de los archivos. Pide a soporte que lo revise."; return 1; }
}
patron() { sed 's/[][*?\\]/\\&/g' <<< "$1"; }  # para -path: el nombre tal cual, sin comodines
ajenos() {
  local m poda=(-path "$(patron "$casa")/.local/share/containers" -o -path "$(patron "$casa")/.local/share/docker")
  while read -r _ _ _ _ m _; do  # discos montados dentro de la carpeta: ni su raíz (-xdev no baja, pero la toca)
    m=$(printf '%b' "$m")  # mountinfo escribe los espacios como \040
    case $m in "$casa"/*) poda+=(-o -path "$(patron "$m")") ;; esac
  done < /proc/self/mountinfo
  timeout 500 find "$casa" -xdev \( "${poda[@]}" \) -prune \
    -o ! -user "$uid" \( -type d -o -type l -o \( -type f -links 1 \) \) "$@" 2>/dev/null
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  l=$(ajenos -printf '%u\t%P\n'; echo "fin	$?")
  cortada=0; [ "${l##*$'\n'}" = "fin	124" ] && cortada=1
  l=$(grep -v '^fin	[0-9]*$' <<< "$l")
  if [ -z "$l" ]; then
    echo "Todos los archivos de tu carpeta personal ya son tuyos."
    echo "Si te sigue diciendo «permiso denegado», puede ser el disco en solo lectura o una carpeta compartida: pide a soporte que lo revise."
    [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera."
    exit 10
  fi
  duenos=$(cut -f1 <<< "$l" | sort | uniq -c | sort -rn | head -3 | awk '{ printf "%s%s (%d)", s, $2, $1; s = ", " }')
  echo "Hay $(grep -c . <<< "$l") archivo(s) o carpeta(s) en tu carpeta personal que son de otra cuenta: $duenos."
  cut -f2- <<< "$l" | head -3 | sed 's|^|- ~/|'
  echo "Si sigo, te los devuelvo para que puedas guardarlos, cambiarlos de nombre o borrarlos."
  [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber más."
  exit 0 ;;
comprobar)
  puedo || exit 3
  exit 0 ;;
aplicar)
  puedo || exit 1
  n=$(ajenos -print | wc -l)
  ajenos -execdir chown -h "$uid" {} +
  q=$(ajenos -print | wc -l)
  [ "$q" -eq 0 ] || { echo "Devolví $((n - q)) archivo(s), pero no pude con $q: pide a soporte que lo revise."; exit 1; }
  echo "Te devolví $n archivo(s) o carpeta(s) de tu carpeta personal. Prueba de nuevo a guardar o cambiar el archivo."
  exit 0 ;;
verificar)
  puedo || exit 1
  q=$(ajenos -print | wc -l)
  [ "$q" -eq 0 ] || { echo "Todavía hay $q archivo(s) que no son tuyos."; exit 1; }
  echo "Todos los archivos de tu carpeta personal son tuyos."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
