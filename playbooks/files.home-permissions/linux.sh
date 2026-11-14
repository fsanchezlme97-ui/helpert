#!/bin/bash
# Devolver a la persona la propiedad de los archivos de su carpeta personal que quedaron a nombre de otra cuenta
# (típico tras usar sudo). Cambiar el dueño necesita root, así que aquí no se puede actuar como la persona; por eso:
# - solo cuentas de personas (UID 1000 o más) con la carpeta en /home o /var/home;
# - sin cruzar a otros discos (-xdev) ni entrar en los contenedores sin root (usan cuentas propias a propósito);
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
}
ajenos() {
  timeout 500 find "$casa" -xdev \( -path "$casa/.local/share/containers" -o -path "$casa/.local/share/docker" \) -prune \
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
