#!/bin/bash
# Devolver a la persona la propiedad de los archivos de su carpeta personal que quedaron a nombre de otra cuenta
# (típico tras usar sudo). Cambiar el dueño necesita root, así que aquí no se puede actuar como la persona; por eso:
# - solo cuentas de personas (UID 501 o más) con la carpeta en /Users;
# - sin cruzar a otros discos (-xdev) ni tocar la raíz de uno montado dentro;
# - macOS deja enlazar (enlace duro) archivos ajenos, y entre revisar y cambiar el dueño la persona podría cambiar un
#   archivo por un enlace a uno del sistema: ninguna revisión de enlaces lo evita (ni la de la carpeta: tiene ACL).
#   Por eso root solo cambia el dueño de carpetas (fchown sobre lo abierto sin seguir enlaces, tras revisar disco y
#   dueño), que no se pueden enlazar. Los archivos los copia y reemplaza la propia persona, con su cuenta, después de
#   recibir sus carpetas: no gana nada que no pudiera hacer ella; si no puede leerlos, va a soporte;
# - los enlaces simbólicos no se tocan: su dueño no impide guardar ni borrar.
# Solo cambia el dueño. macOS puede negar el acceso a carpetas protegidas (TCC): si pasa, se dice.
set -u
usuario=${HP_USUARIO:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
uid=$(id -u "$usuario" 2>/dev/null)

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ] && [ "$uid" -ge 501 ] && [ "$uid" -lt 60000 ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide, o su cuenta no es de una persona."; return 1; }
  local ok=0
  case $casa in
  */../*|*/..) ;;  # con «..» podría salir de /Users
  /Users/?*) ok=1 ;;
  esac
  [ "$ok" = 1 ] || { echo "Tu carpeta personal ($casa) no está donde suelen estar: no la toco. Pide a soporte que la revise."; return 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para cambiar a quién pertenecen los archivos."; return 1; }
}
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
ajenos() { find "$casa" -xdev ! -user "$uid" \( -type d -o \( -type f -links 1 \) \) "$@"; }
# argumentos: uid, disco de la carpeta personal y los nombres, desde su carpeta (-execdir)
devolver='use Fcntl; my ($u, $d) = splice(@ARGV, 0, 2);
for (@ARGV) {
  sysopen(my $f, $_, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or next;
  my @s = stat($f) or next;
  next if $s[0] != $d || $s[4] == $u || !-d _;
  chown($u, -1, $f);
}'
cuantos() { ajenos -print 2>/dev/null | wc -l | tr -d ' '; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  t=$(mktemp) && e=$(mktemp) || { echo "No pude crear un archivo temporal."; exit 1; }
  trap 'rm -f "$t" "$e"' EXIT
  cortada=0
  tope 400 ajenos -exec stat -f '%Su'$'\t''%N' {} + > "$t" 2> "$e" || [ $? -ne 124 ] || cortada=1
  tcc=""; grep -q 'Operation not permitted' "$e" && tcc="macOS no me dejó revisar algunas carpetas protegidas (como Documentos o Escritorio): pide a soporte que le dé a Helpert «Acceso total al disco»."
  if [ ! -s "$t" ]; then
    echo "Todos los archivos de tu carpeta personal ya son tuyos."
    echo "Si te sigue diciendo «permiso denegado», puede ser un disco en solo lectura o una carpeta compartida: pide a soporte que lo revise."
    [ -n "$tcc" ] && echo "$tcc"
    [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera."
    exit 10
  fi
  duenos=$(cut -f1 "$t" | sort | uniq -c | sort -rn | head -3 | awk '{ printf "%s%s (%d)", s, $2, $1; s = ", " }')
  echo "Hay $(wc -l < "$t" | tr -d ' ') archivo(s) o carpeta(s) en tu carpeta personal que son de otra cuenta: $duenos."
  cut -f2- "$t" | head -3 | awk -v c="$casa" '{ print "- ~" (index($0, c) == 1 ? substr($0, length(c) + 1) : $0) }'
  echo "Si sigo, te los devuelvo para que puedas guardarlos, cambiarlos de nombre o borrarlos."
  [ -n "$tcc" ] && echo "$tcc"
  [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber más."
  exit 0 ;;
comprobar)
  puedo || exit 3
  exit 0 ;;
aplicar)
  puedo || exit 1
  n=$(cuantos)
  [ -x /usr/bin/perl ] || { echo "Falta una herramienta de macOS (perl) para hacerlo con seguridad. Pide a soporte que lo revise."; exit 1; }
  ajenos -type d -execdir /usr/bin/perl -e "$devolver" "$uid" "$(stat -f %d "$casa")" {} + 2>/dev/null
  ajenos -type f -execdir /usr/bin/sudo -u "$usuario" /bin/sh -c 'cp -p "$1" "$1.helpert-tmp" && mv -f "$1.helpert-tmp" "$1" || rm -f "$1.helpert-tmp"' helpert {} \; 2>/dev/null
  q=$(cuantos)
  [ "${q:-0}" -eq 0 ] || { echo "Devolví $((n - q)) archivo(s), pero no pude con $q: pide a soporte que lo revise."; exit 1; }
  echo "Te devolví $n archivo(s) o carpeta(s) de tu carpeta personal. Prueba de nuevo a guardar o cambiar el archivo."
  exit 0 ;;
verificar)
  puedo || exit 1
  q=$(cuantos)
  [ "${q:-0}" -eq 0 ] || { echo "Todavía hay $q archivo(s) que no son tuyos."; exit 1; }
  echo "Todos los archivos de tu carpeta personal son tuyos."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
