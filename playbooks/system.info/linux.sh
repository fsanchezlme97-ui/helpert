#!/bin/bash
# Ver los datos del equipo: nombre, sistema, número de serie, memoria, disco e IP. Solo lectura: termina con 10.
set -u
dmi() { tr -d '\n' 2>/dev/null < "/sys/class/dmi/id/$1"; }

case ${1:-} in
diagnosticar)
  sistema=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  fabricante="$(dmi sys_vendor) $(dmi product_name)"
  serie=$(dmi product_serial)
  case $serie in ''|'To be filled'*|'Default string'|'System Serial Number'|0) serie="no disponible" ;; esac
  memoria=$(awk '/^MemTotal/ {printf "%.1f", $2 / 1048576}' /proc/meminfo)
  disco=$(df -Pk / | awk 'NR == 2 {printf "%.0f GB en total, %.0f GB libres", $2 / 1048576, $4 / 1048576}')
  ip=$(command -v ip >/dev/null && ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "Nombre del equipo: $(cat /proc/sys/kernel/hostname)"
  echo "Sistema: $sistema (núcleo $(uname -r))"
  [ "$fabricante" != " " ] && echo "Modelo: $fabricante"
  echo "Número de serie: $serie"
  echo "Memoria: $memoria GB"
  echo "Disco del sistema: $disco"
  echo "Dirección IP: ${ip:-sin conexión de red}"
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
