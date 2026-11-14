#!/bin/bash
# Expulsar una memoria USB o disco externo: dice qué programa la usa (fuser), escribe lo pendiente (sync), la
# desmonta y la apaga (udisksctl power-off), como «Expulsar» en el escritorio. Nunca cierra programas: si está en uso,
# la persona los cierra. Solo discos USB o extraíbles montados en /media, /run/media o /mnt: nunca el del sistema.
set -u
externos() { lsblk -rdpno NAME,RM,TRAN 2>/dev/null | awk '$2 == 1 || $3 == "usb" {print $1}'; }
# «disco|punto de montaje» de cada memoria abierta (lsblk escribe los espacios como \x20)
montajes() {
  for d in $(externos); do
    m=$(lsblk -rpno MOUNTPOINT "$d" 2>/dev/null | grep .)
    [ -n "$m" ] || continue
    echo "$m" | grep -qvE '^/(media|run/media|mnt)/' && continue  # tiene algo del sistema: no se toca
    echo "$m" | while read -r x; do echo "$d|$(printf '%b' "$x")"; done
  done
}
nombres() { echo "$1" | sed 's/^.*\///' | sort -u | sed 's/.*/«&»/' | paste -sd, - | sed 's/,/, /g'; }
# programas que tienen algo abierto en esas memorias
usando() {
  command -v fuser >/dev/null || return 0
  echo "$1" | while IFS='|' read -r _ m; do fuser -m "$m" 2>/dev/null; done | tr ' ' '\n' | grep -o '[0-9]*' | sort -u |
    while read -r p; do ps -o comm= -p "$p" 2>/dev/null; done | sort -u | paste -sd, - | sed 's/,/, /g'
}

case ${1:-} in
diagnosticar)
  command -v lsblk >/dev/null || { echo "No puedo ver los discos de este equipo (falta lsblk)."; exit 1; }
  l=$(montajes)
  [ -n "$l" ] || { echo "No hay ninguna memoria USB ni disco externo abierto: ya puedes desconectarlo."; exit 10; }
  echo "Memoria abierta: $(nombres "$(echo "$l" | cut -d'|' -f2)")."
  u=$(usando "$l")
  if [ -n "$u" ]; then echo "La está usando: $u. Guarda tu trabajo y cierra esos programas; después la expulso."
  else
    command -v fuser >/dev/null || echo "No puedo saber qué programa la usa (falta fuser): si alguno tiene archivos de la memoria abiertos, ciérralo."
    echo "Voy a terminar de guardar lo pendiente y expulsarla."
  fi
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para expulsar la memoria."; exit 3; }
  l=$(montajes)
  [ -n "$l" ] || { echo "Ya no hay ninguna memoria abierta."; exit 3; }
  u=$(usando "$l")
  [ -z "$u" ] || { echo "Todavía la está usando: $u. Guarda tu trabajo, cierra esos programas y vuelve a intentarlo."; exit 3; }
  exit 0 ;;
aplicar)
  l=$(montajes)
  [ -n "$l" ] || { echo "No había ninguna memoria abierta: ya puedes desconectarla."; exit 0; }
  sync
  mal=""
  while IFS='|' read -r _ m; do umount "$m" 2>/dev/null || mal="$mal|$m"; done <<< "$l"
  [ -z "$mal" ] || { echo "No pude expulsar $(nombres "$(echo "${mal#|}" | tr '|' '\n')"): algún programa la sigue usando. Ciérralo y vuelve a intentarlo."; exit 1; }
  if command -v udisksctl >/dev/null; then
    for d in $(echo "$l" | cut -d'|' -f1 | sort -u); do udisksctl power-off --no-user-interaction -b "$d" >/dev/null 2>&1; done
  fi
  echo "Guardé lo pendiente y expulsé $(nombres "$(echo "$l" | cut -d'|' -f2)")."
  exit 0 ;;
verificar)
  [ -z "$(montajes)" ] || { echo "La memoria sigue abierta: no la desconectes todavía."; exit 1; }
  echo "Ya puedes desconectar la memoria con seguridad."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
