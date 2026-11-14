#!/bin/bash
# Ver los datos del Mac: nombre, sistema, número de serie, memoria, disco e IP. Solo lectura: termina con 10.
set -u
case ${1:-} in
diagnosticar)
  nombre=$(scutil --get ComputerName 2>/dev/null || hostname)
  modelo=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ {print $2; exit}')
  serie=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/ {print $4; exit}')
  memoria=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1 / 1073741824}')
  # en APFS los datos viven en su propio volumen; el del sistema es de solo lectura
  vol=/System/Volumes/Data; [ -d "$vol" ] || vol=/
  disco=$(df -k "$vol" | awk 'NR == 2 {printf "%.0f GB en total, %.0f GB libres", $2 / 1048576, $4 / 1048576}')
  interfaz=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
  ip=; [ -n "$interfaz" ] && ip=$(ipconfig getifaddr "$interfaz" 2>/dev/null)
  echo "Nombre del equipo: $nombre"
  echo "Sistema: macOS $(sw_vers -productVersion) (compilación $(sw_vers -buildVersion))"
  [ -n "$modelo" ] && echo "Modelo: $modelo"
  echo "Número de serie: ${serie:-no disponible}"
  echo "Memoria: ${memoria:-?} GB"
  echo "Disco del sistema: $disco"
  echo "Dirección IP: ${ip:-sin conexión de red}"
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
