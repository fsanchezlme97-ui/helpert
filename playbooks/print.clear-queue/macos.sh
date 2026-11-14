#!/bin/bash
# Liberar cola de impresión (CUPS de macOS). Uso: macos.sh diagnosticar|comprobar|aplicar|verificar
# Salida: resumen para el usuario. Códigos: 0 bien (en diagnosticar: hay algo que hacer), 10 nada que hacer, otro fallo.
set -u
imp=${HP_IMPRESORA:-}

trabajos() { lpstat -o ${imp:+"$imp"} 2>/dev/null; }
pausadas() { lpstat -p ${imp:+"$imp"} 2>/dev/null | awk '$1 == "printer" && /disabled/ {print $2}'; }
cups_activo() { lpstat -r 2>/dev/null | grep -q 'is running'; }

case ${1:-} in
diagnosticar)
  command -v lpstat >/dev/null || { echo "Este equipo no tiene el sistema de impresión (CUPS) instalado."; exit 1; }
  cups_activo || { echo "El servicio de impresión está detenido."; exit 0; }
  n=$(trabajos | grep -c .); p=$(pausadas)
  [ "$n" -eq 0 ] && [ -z "$p" ] && { echo "La cola de impresión está vacía, ninguna impresora está en pausa y el servicio funciona."; exit 10; }
  [ "$n" -gt 0 ] && { echo "Hay $n trabajo(s) atascado(s) en la cola${imp:+ de $imp}:"; trabajos | head -8 | awk '{print "- " $1}'; }
  [ -n "$p" ] && echo "Impresora(s) en pausa: $(echo $p)."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar la impresión."; exit 3; }
  if [ -n "$imp" ] && ! lpstat -p "$imp" >/dev/null 2>&1; then echo "No existe la impresora $imp en este equipo."; exit 3; fi
  exit 0 ;;
aplicar)
  n=$(trabajos | grep -c .)
  cancel -a ${imp:+"$imp"} 2>/dev/null
  for p in $(pausadas); do cupsenable "$p" 2>/dev/null; done
  # cupsd lo arranca launchd cuando hace falta; si kickstart no puede, se cierra y launchd lo vuelve a abrir
  launchctl kickstart -k system/org.cups.cupsd >/dev/null 2>&1 || killall cupsd 2>/dev/null
  for _ in 1 2 3 4 5; do cups_activo && break; sleep 1; done
  cups_activo || { echo "No se pudo reiniciar el servicio de impresión."; exit 1; }
  echo "Borré $n trabajo(s) atascado(s), reactivé las impresoras en pausa y reinicié el servicio de impresión."
  exit 0 ;;
verificar)
  for _ in 1 2 3 4 5; do cups_activo && break; sleep 1; done
  cups_activo || { echo "El servicio de impresión no volvió a arrancar."; exit 1; }
  [ "$(trabajos | grep -c .)" -eq 0 ] && [ -z "$(pausadas)" ] || { echo "Todavía quedan trabajos o impresoras en pausa."; exit 1; }
  echo "La cola está vacía y la impresión funciona."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
