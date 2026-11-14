#!/bin/bash
# Cerrar un programa congelado en macOS: solo procesos de la persona que pide (por su UID), nunca del sistema, del
# escritorio ni de Helpert. HP_PROGRAMA ya viene validado (letras, números, . _ -). Primero se le pide cerrar (TERM) y,
# si no responde, a la fuerza. Compatible con bash 3.2.
set -u
usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)
prog=$(echo "${HP_PROGRAMA:-}" | tr 'A-Z' 'a-z')
# nombres que la gente dice → nombre del proceso en macOS
case $prog in
  libreoffice|writer|calc|impress) prog=soffice ;;
  word|winword) prog="microsoft word" ;;
  excel) prog="microsoft excel" ;;
  powerpoint|powerpnt) prog="microsoft powerpoint" ;;
  outlook) prog="microsoft outlook" ;;
  chrome|google-chrome) prog="google chrome" ;;
  edge|msedge|microsoft-edge) prog="microsoft edge" ;;
esac
# el escritorio, la sesión y el propio Helpert no se cierran nunca (además de todo lo que vive en /System/Library y /usr)
PROTEGIDOS='^(dock|finder|systemuiserver|windowserver|loginwindow|controlcenter|notificationcenter|launchd|helpert.*|bash|zsh|sh|fish|login|sshd|sudo)$'

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo cerrar programas de otra persona."; return 1; }
  [ ${#prog} -ge 3 ] || { echo "Necesito el nombre del programa (al menos 3 letras)."; return 1; }
}
# «PID<tab>nombre» de los procesos de la persona cuyo nombre contiene el programa (sin distinguir mayúsculas).
# En macOS comm es la ruta completa del ejecutable, con espacios («/Applications/Google Chrome.app/…/Google Chrome»).
procesos() {
  ps -axww -o pid=,uid=,comm= 2>/dev/null | awk -v u="$uid" -v p="$prog" -v prot="$PROTEGIDOS" '
    $2 == u {
      pid = $1; ruta = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", ruta)
      if (ruta ~ /\/System\/Library\/|^\/(usr|bin|sbin)\//) next
      n = ruta; sub(/.*\//, "", n); n = tolower(n)
      if (index(n, p) && n !~ prot) print pid "\t" n
    }'
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  echo "$prog" | grep -qiE "$PROTEGIDOS" && { echo "«${prog}» es parte del sistema o del escritorio: no lo cierro."; exit 1; }
  p=$(procesos)
  [ -n "$p" ] || { echo "No encontré «${HP_PROGRAMA:-}» abierto. Si ya no está, ábrelo de nuevo."; exit 10; }
  echo "Encontré «$(echo "$p" | cut -f2 | sort -u | paste -sd, - | sed 's/,/, /g')» abierto ($(echo "$p" | wc -l | tr -d ' ') proceso(s))."
  echo "Si lo cierro, se pierde lo que no hayas guardado en ese programa."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(procesos)" ] || { echo "El programa ya no está abierto."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  pids=$(procesos | cut -f1)
  [ -n "$pids" ] || { echo "El programa ya estaba cerrado."; exit 0; }
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8; do sleep 1; [ -z "$(procesos)" ] && break; done
  quedan=$(procesos | cut -f1)
  # shellcheck disable=SC2086
  [ -n "$quedan" ] && kill -KILL $quedan 2>/dev/null
  echo "Cerré el programa${quedan:+ a la fuerza, porque no respondía}."
  exit 0 ;;
verificar)
  puedo || exit 1
  sleep 1
  [ -z "$(procesos)" ] || { echo "El programa sigue abierto."; exit 1; }
  echo "El programa está cerrado. Ya puedes abrirlo de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
