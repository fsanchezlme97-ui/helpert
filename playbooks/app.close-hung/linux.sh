#!/bin/bash
# Cerrar un programa congelado: solo procesos de la persona que pide, nunca del sistema ni del escritorio.
# HP_PROGRAMA ya viene validado (letras, números, . _ -). Primero se le pide cerrar (TERM) y, si no responde, a la fuerza.
set -u
usuario=${HP_USUARIO:-}
prog=$(echo "${HP_PROGRAMA:-}" | tr 'A-Z' 'a-z')
# nombres que la gente dice → nombre del proceso
case $prog in
  libreoffice|word|excel|powerpoint|writer|calc|impress) prog=soffice ;;
  chrome|google-chrome) prog=chrome ;;
  edge|msedge|microsoft-edge) prog=msedge ;;
  teams|teams-for-linux) prog=teams ;;
esac
# el escritorio, la sesión y el propio Helpert no se cierran nunca
PROTEGIDOS='^(systemd|sd-pam|dbus.*|gnome-shell|gnome-session.*|plasmashell|kwin.*|hyprland|sway|xorg|xwayland|gdm.*|sddm.*|pipewire.*|wireplumber|helpert.*|bash|zsh|fish|sh|login|sshd)$'

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo cerrar programas de otra persona."; return 1; }
  [ ${#prog} -ge 3 ] || { echo "Necesito el nombre del programa (al menos 3 letras)."; return 1; }
}
# PID y nombre de los procesos de la persona cuyo nombre contiene el programa (sin distinguir mayúsculas)
procesos() { ps -u "$usuario" -o pid=,comm= 2>/dev/null | awk -v p="$prog" -v prot="$PROTEGIDOS" \
             'index(tolower($2), p) && tolower($2) !~ prot {print $1, $2}'; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  echo "$prog" | grep -qiE "$PROTEGIDOS" && { echo "«$prog» es parte del sistema o del escritorio: no lo cierro."; exit 1; }
  p=$(procesos)
  [ -n "$p" ] || { echo "No encontré «${HP_PROGRAMA:-}» abierto. Si ya no está, ábrelo de nuevo."; exit 10; }
  echo "Encontré «$(echo "$p" | awk '{print $2}' | sort -u | paste -sd, | sed 's/,/, /g')» abierto ($(echo "$p" | wc -l) proceso(s))."
  echo "Si lo cierro, se pierde lo que no hayas guardado en ese programa."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(procesos)" ] || { echo "El programa ya no está abierto."; exit 3; }
  exit 0 ;;
aplicar)
  pids=$(procesos | awk '{print $1}')
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  for _ in $(seq 8); do [ -z "$(procesos)" ] && break; sleep 1; done
  quedan=$(procesos | awk '{print $1}')
  # shellcheck disable=SC2086
  [ -n "$quedan" ] && kill -KILL $quedan 2>/dev/null
  echo "Cerré el programa${quedan:+ a la fuerza, porque no respondía}."
  exit 0 ;;
verificar)
  sleep 1
  [ -z "$(procesos)" ] || { echo "El programa sigue abierto."; exit 1; }
  echo "El programa está cerrado. Ya puedes abrirlo de nuevo."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
