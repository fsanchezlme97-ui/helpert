#!/bin/bash
# Liberar espacio en disco. Uso: linux.sh diagnosticar|comprobar|aplicar|verificar
# La papelera queda fuera a propósito: vaciarla necesita una confirmación aparte (ver el plan).
set -u
usuario=${HP_USUARIO:-}
casa=""
[ -n "$usuario" ] && [ "$usuario" != root ] && casa=$(getent passwd "$usuario" | cut -d: -f6)

uso() { df --output=pcent / | tail -1 | tr -dc 0-9; }
mb() { awk '{s+=$1} END {printf "%d", s/1048576}'; }
temporales() { find /tmp /var/tmp -xdev -type f -atime +7 -printf '%s\n' 2>/dev/null | mb; }
cache() { [ -n "$casa" ] && [ -d "$casa/.cache" ] && find "$casa/.cache" -xdev -type f -atime +30 -printf '%s\n' 2>/dev/null | mb || echo 0; }
journal() { journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1; }

case ${1:-} in
diagnosticar)
  t=$(temporales); c=$(cache); total=$((t + c))
  echo "El disco del sistema está al $(uso)% de uso."
  echo "Se pueden liberar unos $total MB: $t MB de temporales y $c MB de caché antigua. Los registros del sistema ocupan $(journal)."
  [ "$total" -ge 100 ] || [ "$(uso)" -ge 90 ] && exit 0
  echo "Hay espacio suficiente y poco que limpiar."
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para limpiar el disco."; exit 3; }
  exit 0 ;;
aplicar)
  antes=$(df --output=avail -m / | tail -1)
  find /tmp /var/tmp -xdev -type f -atime +7 -delete 2>/dev/null
  [ -n "$casa" ] && [ -d "$casa/.cache" ] && runuser -u "$usuario" -- find "$casa/.cache" -xdev -type f -atime +30 -delete 2>/dev/null
  journalctl --vacuum-size=200M >/dev/null 2>&1
  despues=$(df --output=avail -m / | tail -1)
  echo "Liberé $((despues - antes)) MB. El disco quedó al $(uso)% de uso."
  exit 0 ;;
verificar)
  [ "$(uso)" -lt 95 ] || { echo "El disco sigue casi lleno ($(uso)%)."; exit 1; }
  echo "El disco está al $(uso)%, con espacio suficiente."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
