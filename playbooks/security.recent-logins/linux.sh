#!/bin/bash
# Ver los inicios de sesión y los intentos fallidos de los últimos 7 días, según el registro del sistema (journal):
# las sesiones que abre PAM (pantalla de inicio, consola, SSH...) y sus fallos de contraseña. No cuenta sudo, su,
# tareas programadas ni procesos del sistema. Solo lectura: termina con 10.
set -u
NO_LOGIN='^(sudo|sudo-i|su|su-l|runuser|runuser-l|cron|crond|atd|systemd-user|polkit-1|pkexec)$'
auth() { journalctl -q --no-pager --since "7 days ago" -o short-iso SYSLOG_FACILITY=4 SYSLOG_FACILITY=10 2>/dev/null; }
# «cuenta servicio dd/mm HH:MM», una por inicio de sesión, del más viejo al más nuevo
sesiones() {
  printf '%s\n' "$1" | sed -n 's/^[0-9]*-\([0-9]*\)-\([0-9]*\)T\([0-9]*:[0-9]*\).*pam_unix(\([^:]*\):session): session opened for user \([^( ]*\).*/\5 \4 \2\/\1 \3/p' |
    awk -v no="$NO_LOGIN" '$2 !~ no' | while read -r u s f h; do
      id=$(getent passwd "$u" | cut -d: -f3)
      { [ "$u" = root ] || [ "${id:-0}" -ge 1000 ]; } && echo "$u $s $f $h"
    done
}
# «servicio cuenta», una por intento fallido
fallos() {
  printf '%s\n' "$1" | sed -n 's/.*pam_unix(\([^:]*\):auth): authentication failure;.* user=\([^ ]*\).*/\1 \2/p'
  printf '%s\n' "$1" | sed -n 's/.*sshd\[[0-9]*\]: Invalid user \([^ ]*\) from.*/sshd \1/p'
}
como() { case $1 in sshd) echo "por red (SSH)" ;; login) echo "en la consola" ;; sudo|sudo-i) echo "al pedir permisos (sudo)" ;; su|su-l) echo "al cambiar de cuenta (su)" ;; gdm*|sddm*|lightdm*|kde*|xdm*) echo "en la pantalla de inicio" ;; *) echo "en $1" ;; esac; }

case ${1:-} in
diagnosticar)
  command -v journalctl >/dev/null || { echo "No encuentro el registro del sistema (journal) para revisar los inicios de sesión."; exit 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para leer el registro de inicios de sesión."; exit 3; }
  a=$(auth); s=$(sesiones "$a"); f=$(fallos "$a" | grep -v '^$')
  ns=$(printf '%s' "$s" | grep -c .); nf=$(printf '%s' "$f" | grep -c .)
  echo "En los últimos 7 días hubo $ns inicio(s) de sesión y $nf intento(s) fallido(s)."
  printf '%s\n' "$s" | awk 'NF {n[$1]++; ult[$1] = $3 " " $4; por[$1] = $2} END {for (u in n) print u, n[u], ult[u], por[u]}' | head -4 |
    while read -r u n f h por; do echo "- $u: $n inicio(s); el último el $f a las $h, $(como "$por")."; done
  printf '%s\n' "$f" | awk 'NF {c[$1 " " $2]++} END {for (k in c) print c[k], k}' | sort -rn | head -3 |
    while read -r n s u; do echo "- Fallaron $n intento(s) con la cuenta «$u» $(como "$s")."; done
  # si el registro no guarda los 7 días (se borra al reiniciar o es pequeño), se dice
  p=$(journalctl -q --no-pager -o short-unix --since "7 days ago" 2>/dev/null | head -1 | cut -d. -f1)
  [ -n "$p" ] && [ "$p" -gt $(( $(date +%s) - 6 * 86400 )) ] && echo "Ojo: el registro del equipo solo guarda desde el $(date -d "@$p" '+%d/%m %H:%M'); antes de eso no puedo saberlo."
  [ "$nf" -gt 0 ] && echo "Si no reconoces algún intento, cambia tu contraseña y avisa a soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
