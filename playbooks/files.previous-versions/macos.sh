#!/bin/bash
# Recuperar una versión anterior de un archivo desde las instantáneas locales de Time Machine (las que macOS guarda en el
# propio disco, unas 24 horas). Elige el archivo más reciente de la carpeta personal con la palabra en el nombre, monta
# cada instantánea (de la más nueva a la más vieja) en una carpeta temporal de root, de solo lectura, busca la primera
# versión distinta de la actual y la copia al lado como «nombre (versión del AAAA-MM-DD HHMM).ext». Nunca sobrescribe.
# Root solo lista y monta las instantáneas; buscar, leer y copiar el archivo lo hace la persona (sudo -u), con sus
# permisos. Las copias en un disco de Time Machine no se revisan (se dice cómo abrirlas). Bash 3.2, sin timeout: tope.
# HP_ARCHIVO ya viene validado (letras, números, . _ -); se compara como texto literal.
set -u
usuario=${HP_USUARIO:-}
archivo=${HP_ARCHIVO:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
vol=/System/Volumes/Data; [ -d "$vol" ] || vol=/
mnt="" err=""

como() { sudo -u "$usuario" "$@"; }
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &  # pkill: el hijo (sudo) avisa a su vez a find
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
desmontar() { [ -n "$mnt" ] && { umount "$mnt" 2>/dev/null || umount -f "$mnt" 2>/dev/null; }; }
limpiar() { desmontar; [ -n "$mnt" ] && rmdir "$mnt" 2>/dev/null; [ -n "$err" ] && rm -f "$err"; }  # rmdir: nunca borra lo montado
puedo() {
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para ver las instantáneas del sistema."; return 1; }
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  # la instantánea es del volumen de datos: la carpeta personal tiene que estar en él (/Users/…)
  case $casa in */../*|*/..) casa="" ;; /Users/?*) ;; *) casa="" ;; esac
  [ -n "$casa" ] || { echo "Tu carpeta personal no está en el disco del Mac, así que sus instantáneas no la incluyen."; return 1; }
  [ ${#archivo} -ge 3 ] || { echo "Necesito al menos 3 letras del nombre del archivo."; return 1; }
  command -v tmutil >/dev/null && command -v mount_apfs >/dev/null || { echo "Este Mac no tiene las herramientas de Time Machine."; return 1; }
  err=$(mktemp) || { echo "No pude crear un archivo temporal."; return 1; }
  trap limpiar EXIT
}
# deja en $f el archivo más reciente con la palabra (sin ocultas ni Library, ni copias ya recuperadas) y en $n cuántos hay
buscar() {
  local t; t=$(tope 60 como find "$casa" -xdev \( -name '.*' -o -path "$casa/Library" \) -prune -o -type f -iname "*$archivo*" \
    ! -name '*(versión del *' ! -name '~$*' -exec stat -f '%m'$'\t''%N' {} + 2>>"$err" | sort -rn)
  n=$(printf '%s' "$t" | grep -c .)
  f=$(printf '%s\n' "$t" | head -1 | cut -f2-)
  [ -n "$f" ] && return 0
  echo "No encontré archivos con «${archivo}» en el nombre en tu carpeta personal."
  grep -q 'Operation not permitted' "$err" && echo "macOS no me dejó buscar en algunas carpetas protegidas (como Documentos o Escritorio): pide a soporte que le dé a Helpert «Acceso total al disco»."
  return 1
}
# monta, de la más nueva a la más vieja, hasta dar con una versión distinta; deja $fecha y $destino, y la copia en $mnt$f
version() {
  local dev snaps s t actual montadas=0 base=${f##*/} dir=${f%/*} d
  dev=$(df "$vol" 2>/dev/null | awk 'NR == 2 {print $1}')
  snaps=$(tmutil listlocalsnapshots "$vol" 2>/dev/null | grep -E '^com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.local$' | sort -r)
  if [ -z "$snaps" ] || [ -z "$dev" ]; then
    echo "Este Mac no tiene instantáneas locales de Time Machine, así que no hay versiones anteriores de «${base}» en el disco."
    echo "Si usas un disco de Time Machine, conéctalo y abre «Entrar en Time Machine» desde la carpeta del archivo. Si está en iCloud Drive u OneDrive, mira su historial de versiones. Si no, soporte puede revisar las copias de seguridad."
    return 1
  fi
  mnt=$(mktemp -d /private/tmp/helpert-version.XXXXXX) || { echo "No pude crear una carpeta temporal."; mnt=""; return 1; }
  actual=$(como stat -f %m "$f" 2>/dev/null)
  for s in $snaps; do
    [ "$SECONDS" -lt 200 ] || break  # que quede tiempo para copiar y desmontar antes del límite
    tope 30 mount_apfs -o rdonly,nobrowse -s "$s" "$dev" "$mnt" 2>>"$err" || continue
    montadas=$((montadas + 1))
    t=$(como stat -f %m "$mnt$f" 2>/dev/null)
    if [ -n "$t" ] && [ "$t" != "$actual" ]; then
      d=${s#com.apple.TimeMachine.}; d=${d%.local}; fecha="${d%-*} ${d##*-}"; fecha=${fecha:0:15}
      case $base in ?*.*) destino="$dir/${base%.*} (versión del ${fecha}).${base##*.}" ;; *) destino="$dir/$base (versión del ${fecha})" ;; esac
      return 0
    fi
    desmontar
  done
  if [ "$montadas" -eq 0 ]; then
    echo "macOS no me dejó abrir sus instantáneas locales. Pide a soporte que le dé a Helpert «Acceso total al disco»."
  else
    echo "Las instantáneas locales de Time Machine (de las últimas 24 horas) no tienen una versión distinta de «${base}». Si usas un disco de Time Machine, ábrelo con «Entrar en Time Machine»."
  fi
  return 1
}
legible() { echo "${1:0:10} ${1:11:2}:${1:13:2}"; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  buscar || exit 10
  rel=${f#"$casa"}
  echo "Encontré «${f##*/}» en ~${rel%/*} (modificado el $(como stat -t '%Y-%m-%d %H:%M' -f %Sm "$f" 2>/dev/null))."
  version || exit 10
  [ "$n" -gt 1 ] && echo "Hay $n archivos con «${archivo}» en el nombre: elegí el que modificaste por último. Si no es ese, dime una palabra más precisa."
  echo "Hay una versión anterior del $(legible "$fecha") en las instantáneas locales de Time Machine."
  echo "Si sigo, la copio al lado como «${destino##*/}»; tu archivo actual no se toca."
  exit 0 ;;
comprobar)
  puedo || exit 3
  buscar || exit 3
  version || exit 3
  exit 0 ;;
aplicar)
  puedo || exit 1
  buscar || exit 1
  version || exit 1
  como test -e "$destino" || como cp -p -n -- "$mnt$f" "$destino" 2>/dev/null
  como test -e "$destino" || { echo "No pude copiar la versión anterior: puede que no tengas permiso para leerla o escribir en esa carpeta."; exit 1; }
  echo "Copié la versión del $(legible "$fecha") como «~${destino#"$casa"}». Ábrela y, si es la buena, guárdala con el nombre que quieras."
  exit 0 ;;
verificar)
  puedo || exit 1
  buscar || exit 1
  version || exit 1
  como test -e "$destino" || { echo "No encuentro la copia de la versión anterior."; exit 1; }
  echo "La versión anterior está en «~${destino#"$casa"}»."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
