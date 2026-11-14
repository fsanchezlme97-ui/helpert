#!/bin/bash
# Ver qué programa de la persona tiene abierto un archivo y cerrarlo. Solo procesos de la persona (por UID), nunca
# del sistema, del escritorio ni de Helpert; solo archivos de su carpeta personal fuera de carpetas ocultas (así una
# palabra corta no cierra el navegador por un archivo de su caché). Se cierran con los permisos de la persona.
# HP_ARCHIVO ya viene validado (letras, números, . _ -); se compara como texto literal, sin distinguir mayúsculas.
set -u
usuario=${HP_USUARIO:-}
archivo=${HP_ARCHIVO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
uid=$(id -u "$usuario" 2>/dev/null)
PROTEGIDOS='^(systemd|\(sd-pam\)|dbus-.*|gnome-shell|gnome-session.*|plasmashell|kwin.*|ksmserver|kded.*|Xorg|Xwayland|pipewire.*|wireplumber|pulseaudio|gvfs.*|xdg-.*|at-spi.*|tracker-.*|localsearch.*|baloo.*|gsd-.*|sshd|bash|zsh|fish|sh|dash|sudo|runuser|su|login|gdm.*|sddm.*|helpert.*)$'

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo cerrar programas de otra persona."; return 1; }
  [ ${#archivo} -ge 3 ] || { echo "Necesito al menos 3 letras del nombre del archivo."; return 1; }
}
# «pid<TAB>programa<TAB>archivo»: los descriptores abiertos de sus procesos que apuntan a un archivo con esa palabra
abiertos() {
  find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -uid "$uid" -printf '%h\t%l\n' 2>/dev/null |
    awk -F'\t' -v c="$casa/" 'BEGIN { a = tolower(ENVIRON["HP_ARCHIVO"]) }
      index($2, c) == 1 { r = substr($2, length(c) + 1); if (r ~ /(^|\/)\./) next
        n = split(r, x, "/"); if (index(tolower(x[n]), a)) { split($1, p, "/"); print p[3] "\t" $2 } }' | sort -u |
    while IFS=$'\t' read -r pid ruta; do
      prog=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
      [[ $prog =~ $PROTEGIDOS ]] && continue
      printf '%s\t%s\t%s\n' "$pid" "$prog" "$ruta"
    done
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
  echo "Cerré $(wc -l <<< "$p") programa(s) que tenían abierto el archivo. Ya puedes moverlo, borrarlo o abrirlo."
  exit 0 ;;
verificar)
  puedo || exit 1
  sleep 1
  [ -z "$(pids)" ] || { echo "Algún programa sigue con el archivo abierto."; exit 1; }
  echo "Ningún programa tiene abierto el archivo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
