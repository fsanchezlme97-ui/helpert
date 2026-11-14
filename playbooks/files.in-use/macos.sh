#!/bin/bash
# Ver qué programa de la persona tiene abierto un archivo y cerrarlo (macOS, con lsof). Solo procesos de la persona,
# nunca del sistema, del escritorio (Finder, Dock…) ni de Helpert; solo archivos de su carpeta personal fuera de
# carpetas ocultas y de Library. Se cierran con los permisos de la persona (sudo -u).
# HP_ARCHIVO ya viene validado (letras, números, . _ -); se compara como texto literal, sin distinguir mayúsculas.
set -u
usuario=${HP_USUARIO:-}
archivo=${HP_ARCHIVO:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
PROTEGIDOS='^(launchd|loginwindow|Finder|Dock|SystemUIServer|WindowServer|ControlCenter|NotificationCenter|Spotlight|mds.*|mdworker.*|mdbulkimport|mdsync|QuickLook.*|quicklookd|fseventsd|cfprefsd|distnoted|bird|cloudd|fileproviderd|sharingd|bash|zsh|sh|sudo|login|sshd|helpert.*)$'

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo cerrar programas de otra persona."; return 1; }
  [ ${#archivo} -ge 3 ] || { echo "Necesito al menos 3 letras del nombre del archivo."; return 1; }
  command -v lsof >/dev/null || { echo "Falta la herramienta lsof para ver qué programa usa el archivo."; return 1; }
}
# «pid<TAB>programa<TAB>archivo» de sus procesos que tienen abierto un archivo con esa palabra en el nombre
abiertos() {
  lsof +c 0 -nP -u "$usuario" -Fpcn 2>/dev/null | awk -v c="$casa/" -v prot="$PROTEGIDOS" '
    BEGIN { a = tolower(ENVIRON["HP_ARCHIVO"]) }
    /^p/ { pid = substr($0, 2) } /^c/ { prog = substr($0, 2) }
    /^n/ { f = substr($0, 2); if (index(f, c) != 1 || prog ~ prot) next
      r = substr(f, length(c) + 1); if (r ~ /(^|\/)\./ || r ~ /^Library\//) next
      n = split(r, x, "/"); if (index(tolower(x[n]), a)) print pid "\t" prog "\t" f }' | sort -u
}
pids() { abiertos | cut -f1 | sort -u; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  a=$(abiertos)
  if [ -z "$a" ]; then
    echo "Ningún programa tuyo tiene abierto un archivo con «$archivo» en el nombre."
    echo "Si el aviso sigue, cierra sesión y vuelve a entrar. Si el archivo está en una memoria USB o una carpeta de red, puede tenerlo abierto otro equipo."
    exit 10
  fi
  echo "Estos programas tienen abierto el archivo:"
  cut -f2,3 <<< "$a" | sort -u | head -6 | while IFS=$'\t' read -r prog ruta; do echo "- $prog: ~/${ruta#"$casa/"}"; done
  echo "Si sigo, los cierro; lo que no hayas guardado en ellos se pierde."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(pids)" ] || { echo "Ya ningún programa tiene abierto el archivo."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  p=$(pids)
  [ -n "$p" ] || { echo "Ya ningún programa tenía abierto el archivo."; exit 0; }
  # primero se le pide que se cierre; si en 5 segundos no lo hizo, a la fuerza
  como kill -TERM $p 2>/dev/null
  for _ in 1 2 3 4 5; do sleep 1; [ -z "$(pids)" ] && break; done
  q=$(pids); [ -n "$q" ] && como kill -KILL $q 2>/dev/null
  echo "Cerré $(echo "$p" | wc -l | tr -d ' ') programa(s) que tenían abierto el archivo. Ya puedes moverlo, borrarlo o abrirlo."
  exit 0 ;;
verificar)
  puedo || exit 1
  sleep 1
  [ -z "$(pids)" ] || { echo "Algún programa sigue con el archivo abierto."; exit 1; }
  echo "Ningún programa tiene abierto el archivo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
